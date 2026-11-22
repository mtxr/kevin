//! Line-by-line finite state machine that turns a Markdown file into a tree
//! of `Command`s. See README for the accepted syntax.

const std = @import("std");
const ast = @import("ast.zig");
const Allocator = std.mem.Allocator;
const Command = ast.Command;
const Arg = ast.Arg;
const Flag = ast.Flag;
const CodeBlock = ast.CodeBlock;

const State = enum { normal, in_options, in_code_block };

const StackEntry = struct {
    level: u8,
    title: []const u8,
    cmd: ?*Command,
    line: usize,
};

pub const Parsed = struct {
    root: *Command,
    warnings: std.ArrayList([]const u8),
};

/// Parse `src` (kept alive by `arena`) into a command tree.
pub fn parseSource(arena: Allocator, source_path: []const u8, src: []const u8) Allocator.Error!Parsed {
    // Editors on Windows often prepend a UTF-8 byte order mark; it would hide the first heading.
    const no_bom = if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) src[3..] else src;
    // Normalise CRLF so shell blocks never see stray '\r'.
    const text = if (std.mem.indexOfScalar(u8, no_bom, '\r') != null)
        try std.mem.replaceOwned(u8, arena, no_bom, "\r\n", "\n")
    else
        no_bom;

    const root = try arena.create(Command);
    root.* = .{ .name = "", .source_path = source_path };
    var p: Parser = .{ .arena = arena, .source_path = source_path, .src = text, .root = root };
    try p.run();
    try finalizeFlags(arena, root);
    return .{ .root = root, .warnings = p.warnings };
}

/// A flag without a `flags:` line answers to `--<name>` (lowercase, `_` as `-`),
/// which is also what `--help` advertises.
fn finalizeFlags(arena: Allocator, cmd: *Command) Allocator.Error!void {
    for (cmd.flags.items) |*f| {
        if (f.long != null) continue;
        const buf = try arena.alloc(u8, f.name.len + 2);
        buf[0] = '-';
        buf[1] = '-';
        for (f.name, buf[2..]) |c, *d| d.* = if (c == '_') '-' else std.ascii.toLower(c);
        f.long = buf;
    }
    for (cmd.children.items) |c| try finalizeFlags(arena, c);
}

pub const Parser = struct {
    arena: Allocator,
    source_path: []const u8,
    src: []const u8,
    root: *Command,
    warnings: std.ArrayList([]const u8) = .empty,

    state: State = .normal,
    stack: [6]StackEntry = undefined,
    stack_len: usize = 0,
    line_no: usize = 0,

    /// Flags declared before an inline task block (plain heading on top).
    pending_flags: std.ArrayList(Flag) = .empty,
    /// Dependency attributes declared before an inline task block.
    pending_deps: ast.DepSpec = .{},
    /// Command still accepting `> description` lines.
    pending_desc: ?*Command = null,
    opt_target: ?*std.ArrayList(Flag) = null,
    opt_root_indent: ?usize = null,

    fence_char: u8 = 0,
    fence_len: usize = 0,
    fence_indent: usize = 0,
    block_target: ?*Command = null,
    block_lang: []const u8 = "",
    block_start: usize = 0,
    block_line: usize = 0,

    pub fn run(self: *Parser) Allocator.Error!void {
        var pos: usize = 0;
        while (pos < self.src.len) {
            const end = std.mem.indexOfScalarPos(u8, self.src, pos, '\n') orelse self.src.len;
            const line = self.src[pos..end];
            self.line_no += 1;
            try self.feed(line, pos, end);
            pos = end + 1;
        }
        // Unterminated fence: the block runs until EOF.
        if (self.state == .in_code_block) try self.closeBlock(self.src.len);
    }

    fn feed(self: *Parser, line: []const u8, line_start: usize, line_end: usize) Allocator.Error!void {
        switch (self.state) {
            .in_code_block => {
                if (isClosingFence(line, self.fence_char, self.fence_len, self.fence_indent)) {
                    try self.closeBlock(line_start);
                    self.state = .normal;
                }
            },
            .in_options => {
                if (try self.optionsLine(line)) return;
                self.state = .normal;
                try self.normalLine(line, line_start, line_end);
            },
            .normal => try self.normalLine(line, line_start, line_end),
        }
    }

    // ---------------------------------------------------------------- normal

    fn normalLine(self: *Parser, line: []const u8, line_start: usize, line_end: usize) Allocator.Error!void {
        if (parseHeading(line)) |h| return self.heading(h.level, h.text);
        if (parseFence(line)) |f| return self.openFence(f, line_end);
        _ = line_start;

        // `Requires:`, `RunDeps:`, `Run:` and `Jobs:` lines, until the first code block.
        if (parseAttr(line)) |attr| attr_blk: {
            if (self.stack_len == 0) break :attr_blk;
            const top = self.stack[self.stack_len - 1];
            const spec: *ast.DepSpec = if (top.cmd) |c| blk: {
                if (c.blocks.items.len > 0) break :attr_blk;
                break :blk &c.deps;
            } else &self.pending_deps;
            if (try self.applyDep(spec, attr)) return;
        }

        const t = std.mem.trim(u8, line, " \t");
        if (isOptionsMarker(t)) {
            if (self.stack_len == 0) return;
            const top = self.stack[self.stack_len - 1];
            self.opt_target = if (top.cmd) |c| &c.flags else &self.pending_flags;
            self.opt_root_indent = null;
            self.state = .in_options;
            self.pending_desc = null;
            return;
        }
        if (t.len == 0) {
            if (self.pending_desc) |c| {
                // A blank line ends the blockquote once it has started.
                if (c.description.len != 0) self.pending_desc = null;
            }
            return;
        }
        if (t[0] == '>') {
            if (self.pending_desc) |c| {
                const body = std.mem.trim(u8, t[1..], " \t");
                if (c.description.len == 0) {
                    c.description = body;
                } else {
                    c.description = try std.fmt.allocPrint(self.arena, "{s} {s}", .{ c.description, body });
                }
                return;
            }
        }
        self.pending_desc = null;
    }

    fn heading(self: *Parser, level: u8, text: []const u8) Allocator.Error!void {
        while (self.stack_len > 0 and self.stack[self.stack_len - 1].level >= level) self.stack_len -= 1;
        self.pending_flags.clearRetainingCapacity();
        self.pending_deps = .{};
        self.pending_desc = null;

        if (text.len > 0 and text[0] == '>') {
            if (try self.markedCommand(text[1..])) |cmd| {
                self.push(.{ .level = level, .title = text, .cmd = cmd, .line = self.line_no });
                self.pending_desc = cmd;
                return;
            }
        }
        self.push(.{ .level = level, .title = text, .cmd = null, .line = self.line_no });
    }

    fn push(self: *Parser, e: StackEntry) void {
        self.stack[self.stack_len] = e;
        self.stack_len += 1;
    }

    fn nearestParent(self: *Parser) *Command {
        var i = self.stack_len;
        while (i > 0) {
            i -= 1;
            if (self.stack[i].cmd) |c| return c;
        }
        return self.root;
    }

    fn markedCommand(self: *Parser, rest_raw: []const u8) Allocator.Error!?*Command {
        const rest = std.mem.trim(u8, rest_raw, " \t");
        const name_end = std.mem.indexOfAny(u8, rest, " \t([") orelse rest.len;
        const name = rest[0..name_end];
        if (name.len == 0) {
            try self.warn("line {d}: heading marked with '>' has no command name", .{self.line_no});
            return null;
        }
        const cmd = try self.arena.create(Command);
        cmd.* = .{ .name = name, .source_path = self.source_path, .decl_line = self.line_no };
        try parseParams(self.arena, rest[name_end..], &cmd.args);

        const parent = self.nearestParent();
        if (parent.findIndex(name)) |idx| {
            try self.warn("line {d}: duplicate command '{s}', the later definition wins", .{ self.line_no, name });
            parent.children.items[idx] = cmd;
        } else {
            try parent.children.append(self.arena, cmd);
        }
        return cmd;
    }

    // ----------------------------------------------------------------- fences

    fn openFence(self: *Parser, f: Fence, line_end: usize) Allocator.Error!void {
        const info = parseInfo(f.info);
        self.state = .in_code_block;
        self.fence_char = f.ch;
        self.fence_len = f.len;
        self.fence_indent = f.indent;
        self.block_lang = info.lang;
        self.block_start = @min(line_end + 1, self.src.len);
        self.block_line = self.line_no;
        self.block_target = null;
        self.pending_desc = null;
        const deps_spec = self.pending_deps;
        self.pending_deps = .{};

        const top: ?StackEntry = if (self.stack_len > 0) self.stack[self.stack_len - 1] else null;
        if (top) |t| {
            if (t.cmd) |c| {
                // Plain code block under a `>` command.
                self.block_target = c;
                self.pending_flags.clearRetainingCapacity();
                return;
            }
        }
        if (!info.is_task) {
            self.pending_flags.clearRetainingCapacity();
            return;
        }

        // Inline task under a plain heading.
        const name: []const u8 = if (info.custom_name) |n| n else blk: {
            const t = top orelse {
                try self.warn("line {d}: task block without a heading or ':name'", .{self.line_no});
                break :blk "";
            };
            break :blk try slugify(self.arena, t.title);
        };
        if (name.len == 0) {
            if (top != null) try self.warn("line {d}: cannot derive a task name from the heading", .{self.line_no});
            self.pending_flags.clearRetainingCapacity();
            return;
        }
        const decl_line = if (top) |t| t.line else 0;
        const parent = self.nearestParent();
        if (parent.findIndex(name)) |idx| {
            const existing = parent.children.items[idx];
            if (existing.decl_line == decl_line and std.mem.eql(u8, existing.source_path, self.source_path)) {
                // Several task blocks under the same heading form one pipeline.
                self.block_target = existing;
                try existing.flags.appendSlice(self.arena, self.pending_flags.items);
                self.pending_flags.clearRetainingCapacity();
                return;
            }
            try self.warn("line {d}: duplicate command '{s}', the later definition wins", .{ self.line_no, name });
        }
        const cmd = try self.arena.create(Command);
        cmd.* = .{ .name = name, .source_path = self.source_path, .decl_line = decl_line };
        try parseParams(self.arena, info.params, &cmd.args);
        cmd.deps = deps_spec;
        try cmd.flags.appendSlice(self.arena, self.pending_flags.items);
        self.pending_flags.clearRetainingCapacity();
        if (parent.findIndex(name)) |idx| {
            parent.children.items[idx] = cmd;
        } else {
            try parent.children.append(self.arena, cmd);
        }
        self.block_target = cmd;
    }

    fn closeBlock(self: *Parser, end: usize) Allocator.Error!void {
        const target = self.block_target orelse return;
        var code = self.src[@min(self.block_start, end)..end];
        if (self.fence_indent > 0) code = try dedent(self.arena, code, self.fence_indent);
        try target.blocks.append(self.arena, .{
            .lang = self.block_lang,
            .code = code,
            .line = self.block_line,
        });
    }

    // ---------------------------------------------------------------- options

    /// Returns false when the line terminates the OPTIONS list.
    fn optionsLine(self: *Parser, line: []const u8) Allocator.Error!bool {
        const t = std.mem.trim(u8, line, " \t");
        if (t.len == 0) return true;
        if (t[0] != '-' and t[0] != '*' and t[0] != '+') return false;
        if (t.len > 1 and t[1] != ' ' and t[1] != '\t') return false; // e.g. `---`, `**bold**`

        var indent: usize = 0;
        while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) : (indent += 1) {}
        const item = std.mem.trim(u8, t[1..], " \t");
        const target = self.opt_target.?;

        const root_indent = self.opt_root_indent orelse blk: {
            self.opt_root_indent = indent;
            break :blk indent;
        };
        if (indent <= root_indent or target.items.len == 0) {
            const name = std.mem.trim(u8, item, " \t`");
            if (name.len == 0) return true;
            try target.append(self.arena, .{ .name = name });
            return true;
        }
        try self.flagAttr(&target.items[target.items.len - 1], item);
        return true;
    }

    fn flagAttr(self: *Parser, flag: *Flag, item: []const u8) Allocator.Error!void {
        const colon = std.mem.indexOfScalar(u8, item, ':');
        const key = std.mem.trim(u8, if (colon) |c| item[0..c] else item, " \t");
        const val = if (colon) |c| std.mem.trim(u8, item[c + 1 ..], " \t") else "";

        if (std.ascii.eqlIgnoreCase(key, "required")) {
            flag.required = colon == null or !std.ascii.eqlIgnoreCase(val, "false");
        } else if (std.ascii.eqlIgnoreCase(key, "flags") or std.ascii.eqlIgnoreCase(key, "flag")) {
            var it = std.mem.tokenizeAny(u8, val, " \t,");
            while (it.next()) |tok| {
                if (std.mem.startsWith(u8, tok, "--")) {
                    flag.long = tok;
                } else if (tok.len == 2 and tok[0] == '-') {
                    flag.short = tok;
                }
            }
        } else if (std.ascii.eqlIgnoreCase(key, "type")) {
            if (std.ascii.eqlIgnoreCase(val, "string") or std.ascii.eqlIgnoreCase(val, "str")) {
                flag.ftype = .string;
            } else if (std.ascii.eqlIgnoreCase(val, "number") or std.ascii.eqlIgnoreCase(val, "num") or std.ascii.eqlIgnoreCase(val, "int")) {
                flag.ftype = .number;
            } else if (std.ascii.eqlIgnoreCase(val, "boolean") or std.ascii.eqlIgnoreCase(val, "bool")) {
                flag.ftype = .boolean;
            } else {
                try self.warn("line {d}: unknown flag type '{s}'", .{ self.line_no, val });
            }
        } else if (std.ascii.eqlIgnoreCase(key, "desc") or std.ascii.eqlIgnoreCase(key, "description")) {
            flag.desc = val;
        } else if (std.ascii.eqlIgnoreCase(key, "choices")) {
            var list: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, val, ',');
            while (it.next()) |c| {
                const ct = std.mem.trim(u8, c, " \t");
                if (ct.len > 0) try list.append(self.arena, ct);
            }
            flag.choices = try list.toOwnedSlice(self.arena);
        } else {
            try self.warn("line {d}: unknown option attribute '{s}'", .{ self.line_no, key });
        }
    }

    /// Returns false when `attr` is not a kevin dependency attribute (it stays prose).
    fn applyDep(self: *Parser, spec: *ast.DepSpec, attr: Attr) Allocator.Error!bool {
        switch (attr.kind) {
            .requires => {
                var it = std.mem.splitScalar(u8, attr.val, ',');
                while (it.next()) |entry| {
                    const e = stripDecor(entry);
                    if (e.len > 0) try spec.requires.append(self.arena, e);
                }
            },
            .run => {
                if (std.ascii.eqlIgnoreCase(attr.val, "once")) {
                    spec.run_once = true;
                } else if (std.ascii.eqlIgnoreCase(attr.val, "always")) {
                    spec.run_once = false;
                } else return self.badAttr("Run:", "'once' or 'always'", attr.val);
            },
            .run_deps => {
                if (std.ascii.eqlIgnoreCase(attr.val, "async")) {
                    spec.run_deps = .async;
                } else if (std.ascii.eqlIgnoreCase(attr.val, "sync")) {
                    spec.run_deps = .sync;
                } else return self.badAttr("RunDeps:", "'sync' or 'async'", attr.val);
            },
            .jobs => {
                const n = std.fmt.parseInt(u32, attr.val, 10) catch 0;
                if (n == 0) return self.badAttr("Jobs:", "a positive integer", attr.val);
                spec.jobs = n;
            },
            else => return false,
        }
        return true;
    }

    /// A single-word bad value is a typo worth a warning; anything longer is
    /// ordinary prose that merely starts with an attribute name.
    fn badAttr(self: *Parser, key: []const u8, expected: []const u8, val: []const u8) Allocator.Error!bool {
        if (val.len > 12 or std.mem.indexOfAny(u8, val, " \t") != null) return false;
        try self.warn("line {d}: '{s}' expects {s}, got '{s}'", .{ self.line_no, key, expected, val });
        return true;
    }

    fn warn(self: *Parser, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const msg = try std.fmt.allocPrint(self.arena, "{s}: " ++ fmt, .{self.source_path} ++ args);
        try self.warnings.append(self.arena, msg);
    }
};

// ------------------------------------------------------------------ helpers

pub const Heading = struct { level: u8, text: []const u8 };

pub fn parseHeading(line: []const u8) ?Heading {
    var i: usize = 0;
    while (i < line.len and i < 4 and line[i] == ' ') : (i += 1) {}
    if (i > 3) return null;
    var n: usize = 0;
    while (i + n < line.len and line[i + n] == '#') : (n += 1) {}
    if (n == 0 or n > 6) return null;
    const rest = line[i + n ..];
    if (rest.len > 0 and rest[0] != ' ' and rest[0] != '\t') return null;
    var text = std.mem.trim(u8, rest, " \t");
    // Optional closing sequence: `## title ##`.
    const stripped = std.mem.trimEnd(u8, text, "#");
    if (stripped.len != text.len and (stripped.len == 0 or stripped[stripped.len - 1] == ' ' or stripped[stripped.len - 1] == '\t')) {
        text = std.mem.trim(u8, stripped, " \t");
    }
    return .{ .level = @intCast(n), .text = text };
}

pub const Fence = struct { ch: u8, len: usize, indent: usize, info: []const u8 };

pub fn parseFence(line: []const u8) ?Fence {
    var indent: usize = 0;
    while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) : (indent += 1) {}
    if (indent >= line.len) return null;
    const ch = line[indent];
    if (ch != '`' and ch != '~') return null;
    var n: usize = 0;
    while (indent + n < line.len and line[indent + n] == ch) : (n += 1) {}
    if (n < 3) return null;
    const info = std.mem.trim(u8, line[indent + n ..], " \t");
    if (ch == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
    return .{ .ch = ch, .len = n, .indent = indent, .info = info };
}

/// A closing fence is >= `min_len` identical chars followed only by spaces,
/// indented at most 3 columns deeper than the opening fence (CommonMark).
/// Deeper indentation is code content, e.g. a fence shown inside a heredoc.
pub fn isClosingFence(line: []const u8, ch: u8, min_len: usize, open_indent: usize) bool {
    var indent: usize = 0;
    while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) : (indent += 1) {}
    if (indent > open_indent + 3) return false;
    const t = std.mem.trim(u8, line, " \t");
    if (t.len < min_len) return false;
    for (t) |c| if (c != ch) return false;
    return true;
}

fn isOptionsMarker(t: []const u8) bool {
    var s = t;
    if (s.len > 0 and s[s.len - 1] == ':') s = s[0 .. s.len - 1];
    return std.ascii.eqlIgnoreCase(s, "**OPTIONS**");
}

pub const AttrKind = enum { requires, run, run_deps, jobs, directory, env, inputs, interactive };

pub const Attr = struct { kind: AttrKind, val: []const u8 };

const attr_names = [_]struct { []const u8, AttrKind }{
    .{ "requires", .requires },
    .{ "req", .requires },
    .{ "run", .run },
    .{ "rundeps", .run_deps },
    .{ "rundependencies", .run_deps },
    .{ "jobs", .jobs },
    // xc attributes: kevin ignores these, `--from xc` translates them.
    .{ "directory", .directory },
    .{ "dir", .directory },
    .{ "env", .env },
    .{ "environment", .env },
    .{ "inputs", .inputs },
    .{ "interactive", .interactive },
};

/// Strips spaces and Markdown emphasis characters (`_`, `*`, backticks).
pub fn stripDecor(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t_*`");
}

/// Recognises `Key: value` attribute lines, tolerating `**Key**:` and `` `value` `` decoration.
pub fn parseAttr(line: []const u8) ?Attr {
    const t = std.mem.trim(u8, line, " \t");
    const colon = std.mem.indexOfScalar(u8, t, ':') orelse return null;
    const key = stripDecor(t[0..colon]);
    for (attr_names) |n| {
        if (std.ascii.eqlIgnoreCase(key, n[0])) return .{ .kind = n[1], .val = stripDecor(t[colon + 1 ..]) };
    }
    return null;
}

const Info = struct {
    lang: []const u8,
    is_task: bool,
    custom_name: ?[]const u8,
    /// Text after the `task` keyword.
    params: []const u8,
};

fn parseInfo(info: []const u8) Info {
    const lang_end = std.mem.indexOfAny(u8, info, " \t") orelse info.len;
    var res: Info = .{ .lang = info[0..lang_end], .is_task = false, .custom_name = null, .params = "" };
    var pos = lang_end;
    while (pos < info.len) {
        while (pos < info.len and (info[pos] == ' ' or info[pos] == '\t')) : (pos += 1) {}
        const tok_end = std.mem.indexOfAnyPos(u8, info, pos, " \t") orelse info.len;
        const tok = info[pos..tok_end];
        if (std.mem.eql(u8, tok, "task")) {
            res.is_task = true;
            res.params = info[tok_end..];
            return res;
        }
        if (std.mem.startsWith(u8, tok, "task:") and tok.len > 5) {
            res.is_task = true;
            res.custom_name = tok[5..];
            res.params = info[tok_end..];
            return res;
        }
        pos = tok_end;
    }
    return res;
}

/// Parses `(required)` and `[optional]` groups.
fn parseParams(arena: Allocator, text: []const u8, out: *std.ArrayList(Arg)) Allocator.Error!void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const close: u8 = switch (text[i]) {
            '(' => ')',
            '[' => ']',
            else => continue,
        };
        const end = std.mem.indexOfScalarPos(u8, text, i + 1, close) orelse return;
        const name = std.mem.trim(u8, text[i + 1 .. end], " \t");
        if (name.len > 0) try out.append(arena, .{ .name = name, .required = close == ')' });
        i = end;
    }
}

fn dedent(arena: Allocator, code: []const u8, indent: usize) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, code, '\n');
    var first = true;
    while (it.next()) |l| {
        if (!first) try out.append(arena, '\n');
        first = false;
        var skip: usize = 0;
        while (skip < indent and skip < l.len and (l[skip] == ' ' or l[skip] == '\t')) : (skip += 1) {}
        try out.appendSlice(arena, l[skip..]);
    }
    return out.items;
}

const latin1_fold = "AAAAAAACEEEEIIIIDNOOOOO*OUUUUYTs" ++ "aaaaaaaceeeeiiiidnooooo/ouuuuyty";

/// "Rodar Migrações" -> "rodar-migracoes"
pub fn slugify(arena: Allocator, title: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var view = std.unicode.Utf8View.initUnchecked(title);
    var it = view.iterator();
    var pending_dash = false;
    while (it.nextCodepoint()) |cp| {
        var c: u8 = 0;
        if (cp < 0x80) {
            c = std.ascii.toLower(@intCast(cp));
        } else if (cp >= 0xC0 and cp <= 0xFF) {
            c = std.ascii.toLower(latin1_fold[cp - 0xC0]);
        }
        if (std.ascii.isAlphanumeric(c)) {
            if (pending_dash and out.items.len > 0) try out.append(arena, '-');
            pending_dash = false;
            try out.append(arena, c);
        } else {
            pending_dash = true;
        }
    }
    return out.items;
}

// -------------------------------------------------------------------- tests

const testing = std.testing;

fn parseForTest(arena: Allocator, src: []const u8) !Parsed {
    return parseSource(arena, "/tmp/test.md", src);
}

test "nested subcommands with > headings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\# Project
        \\
        \\## > setup
        \\> Prepare the environment
        \\> in two lines
        \\
        \\```bash
        \\echo setup
        \\```
        \\
        \\### > server (port) [env]
        \\> Start the server
        \\
        \\```sh
        \\echo $port
        \\```
        \\
        \\## > deploy
        \\
    ;
    const parsed = try parseForTest(arena, src);
    const root = parsed.root;
    try testing.expectEqual(@as(usize, 2), root.children.items.len);

    const setup = root.find("setup").?;
    try testing.expectEqualStrings("Prepare the environment in two lines", setup.description);
    try testing.expectEqual(@as(usize, 1), setup.blocks.items.len);
    try testing.expectEqualStrings("bash", setup.blocks.items[0].lang);
    try testing.expectEqualStrings("echo setup\n", setup.blocks.items[0].code);

    const server = setup.find("server").?;
    try testing.expectEqualStrings("Start the server", server.description);
    try testing.expectEqual(@as(usize, 2), server.args.items.len);
    try testing.expectEqualStrings("port", server.args.items[0].name);
    try testing.expect(server.args.items[0].required);
    try testing.expectEqualStrings("env", server.args.items[1].name);
    try testing.expect(!server.args.items[1].required);

    // `deploy` is a sibling of setup, not a child of it.
    try testing.expect(root.find("deploy") != null);
    try testing.expect(setup.find("deploy") == null);
}

test "inline task blocks and slugified names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\## Rodar Migrações
        \\
        \\```bash task (env) [steps]
        \\echo migrate
        \\```
        \\
        \\## Other
        \\
        \\```ts task:custom-name (x)
        \\console.log(1)
        \\```
        \\
        \\```bash
        \\echo not a task
        \\```
        \\
    ;
    const root = (try parseForTest(arena, src)).root;
    try testing.expectEqual(@as(usize, 2), root.children.items.len);

    const mig = root.find("rodar-migracoes").?;
    try testing.expectEqual(@as(usize, 2), mig.args.items.len);
    try testing.expect(mig.args.items[0].required);
    try testing.expectEqualStrings("echo migrate\n", mig.blocks.items[0].code);

    const custom = root.find("custom-name").?;
    try testing.expectEqualStrings("ts", custom.blocks.items[0].lang);
    try testing.expectEqual(@as(usize, 1), custom.blocks.items.len);
}

test "inline tasks do not leak into preceding > commands" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\## > build
        \\
        \\### Notes
        \\
        \\```bash
        \\echo this is just documentation
        \\```
        \\
        \\```bash task
        \\echo inline
        \\```
        \\
    ;
    const root = (try parseForTest(arena, src)).root;
    const build = root.find("build").?;
    // Untagged block under the plain sub-heading is ignored; the task is a child of `build`.
    try testing.expectEqual(@as(usize, 0), build.blocks.items.len);
    try testing.expect(build.find("notes") != null);
}

test "typed flags from **OPTIONS**" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\## > serve
        \\
        \\**OPTIONS**
        \\* port
        \\    * flags: -p --port
        \\    * type: number
        \\    * desc: Port to listen on
        \\    * required
        \\* env
        \\    * flags: -e --env
        \\    * type: string
        \\    * choices: dev, staging, prod
        \\* watch
        \\    * flags: -w --watch
        \\
        \\```bash
        \\echo $port
        \\```
        \\
        \\## Inline
        \\
        \\**OPTIONS**
        \\- name
        \\  - flags: --name
        \\  - type: string
        \\
        \\```bash task
        \\echo $name
        \\```
        \\
    ;
    const root = (try parseForTest(arena, src)).root;
    const serve = root.find("serve").?;
    try testing.expectEqual(@as(usize, 3), serve.flags.items.len);

    const port = serve.flags.items[0];
    try testing.expectEqualStrings("port", port.name);
    try testing.expectEqualStrings("-p", port.short.?);
    try testing.expectEqualStrings("--port", port.long.?);
    try testing.expectEqual(ast.FlagType.number, port.ftype);
    try testing.expectEqualStrings("Port to listen on", port.desc);
    try testing.expect(port.required);

    const env = serve.flags.items[1];
    try testing.expectEqual(ast.FlagType.string, env.ftype);
    try testing.expectEqual(@as(usize, 3), env.choices.len);
    try testing.expectEqualStrings("staging", env.choices[1]);
    try testing.expect(!env.required);

    // Omitted type defaults to boolean.
    try testing.expectEqual(ast.FlagType.boolean, serve.flags.items[2].ftype);

    // Flags declared before an inline task attach to that task.
    const inl = root.find("inline").?;
    try testing.expectEqual(@as(usize, 1), inl.flags.items.len);
    try testing.expectEqualStrings("--name", inl.flags.items[0].long.?);
    try testing.expectEqual(@as(usize, 0), serve.children.items.len);
}

test "code blocks containing inner triple backticks and markers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\## > docs
        \\
        \\````md
        \\# Not a heading
        \\## > not-a-command
        \\**OPTIONS**
        \\* nope
        \\```bash
        \\inner
        \\```
        \\````
        \\
        \\~~~~bash
        \\cat <<'EOF'
        \\~~~
        \\EOF
        \\~~~~
        \\
        \\## > after
        \\
    ;
    const root = (try parseForTest(arena, src)).root;
    try testing.expectEqual(@as(usize, 2), root.children.items.len);
    const docs = root.find("docs").?;
    try testing.expectEqual(@as(usize, 0), docs.flags.items.len);
    try testing.expectEqual(@as(usize, 2), docs.blocks.items.len);
    try testing.expect(std.mem.indexOf(u8, docs.blocks.items[0].code, "## > not-a-command") != null);
    try testing.expect(std.mem.indexOf(u8, docs.blocks.items[0].code, "```bash\ninner\n```") != null);
    try testing.expectEqualStrings("cat <<'EOF'\n~~~\nEOF\n", docs.blocks.items[1].code);
    try testing.expect(root.find("not-a-command") == null);
    try testing.expect(root.find("after") != null);
}

test "several blocks under one command and under one inline heading" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\## > build
        \\
        \\```bash
        \\echo one
        \\```
        \\
        \\```python
        \\print("two")
        \\```
        \\
        \\```json
        \\{"a": 1}
        \\```
        \\
        \\## Pipeline
        \\
        \\```bash task
        \\echo a
        \\```
        \\
        \\```python task
        \\print("b")
        \\```
        \\
    ;
    const root = (try parseForTest(arena, src)).root;
    try testing.expectEqual(@as(usize, 3), root.find("build").?.blocks.items.len);
    try testing.expectEqual(@as(usize, 2), root.find("pipeline").?.blocks.items.len);
}

test "merging files: namespaces merge, conflicts override with a warning" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try parseSource(arena, "/a.md", "## > db\n\n### > up\n\n```sh\necho a\n```\n");
    const b = try parseSource(arena, "/b.md", "## > db\n\n### > down\n\n```sh\necho b\n```\n\n### > up\n\n```sh\necho b-up\n```\n");
    var warnings: std.ArrayList([]const u8) = .empty;
    try ast.merge(arena, a.root, b.root, &warnings);

    const db = a.root.find("db").?;
    try testing.expectEqual(@as(usize, 2), db.children.items.len);
    try testing.expectEqualStrings("echo b-up\n", db.find("up").?.blocks.items[0].code);
    try testing.expectEqual(@as(usize, 1), warnings.items.len);
}

test "slugify" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("rodar-migracoes", try slugify(arena, "Rodar Migrações"));
    try testing.expectEqualStrings("a-b-c", try slugify(arena, "  A -- B / C!  "));
}

test "dependency attributes on marked and inline commands" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\## > deploy
        \\> Ship it
        \\
        \\Requires: test, build web
        \\**RunDeps**: async
        \\`Jobs`: 2
        \\Run: once
        \\
        \\```sh
        \\echo deploy
        \\Requires: not an attribute once code has started
        \\```
        \\
        \\## Docs
        \\
        \\req: deploy
        \\
        \\```sh task
        \\echo docs
        \\```
        \\
        \\## > group
        \\
        \\Requires: deploy
        \\
    ;
    const parsed = try parseForTest(arena, src);
    const root = parsed.root;
    const deploy = root.find("deploy").?;
    try testing.expectEqual(@as(usize, 2), deploy.deps.requires.items.len);
    try testing.expectEqualStrings("test", deploy.deps.requires.items[0]);
    try testing.expectEqualStrings("build web", deploy.deps.requires.items[1]);
    try testing.expectEqual(ast.RunDeps.async, deploy.deps.run_deps);
    try testing.expectEqual(@as(?u32, 2), deploy.deps.jobs);
    try testing.expect(deploy.deps.run_once);
    try testing.expectEqualStrings("Ship it", deploy.description);
    try testing.expect(std.mem.indexOf(u8, deploy.blocks.items[0].code, "Requires: not an attribute") != null);

    const docs = root.find("docs").?;
    try testing.expectEqual(@as(usize, 1), docs.deps.requires.items.len);
    try testing.expectEqual(ast.RunDeps.sync, docs.deps.run_deps);

    // A command with only dependencies is a runnable group, not a namespace.
    const group = root.find("group").?;
    try testing.expect(group.hasWork());
    try testing.expectEqual(@as(usize, 0), group.blocks.items.len);
    try testing.expectEqual(@as(usize, 0), parsed.warnings.items.len);
}

test "attribute-like prose is left alone and typos are reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\## > a
        \\
        \\RunDeps: is described in the manual, see below
        \\RunDeps: asynch
        \\
        \\```sh
        \\true
        \\```
        \\
    ;
    const parsed = try parseForTest(arena, src);
    const a = parsed.root.find("a").?;
    try testing.expectEqual(ast.RunDeps.sync, a.deps.run_deps);
    // Only the single-word typo warns; the sentence is prose.
    try testing.expectEqual(@as(usize, 1), parsed.warnings.items.len);
    try testing.expect(std.mem.indexOf(u8, parsed.warnings.items[0], "'asynch'") != null);
}

test "a fence-like line indented inside a block does not close it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\## > doc
        \\
        \\```sh
        \\cat <<'EOF'
        \\    ```
        \\    code sample
        \\    ```
        \\EOF
        \\echo after
        \\```
        \\
        \\- item
        \\
        \\    ```sh
        \\    echo in list
        \\    ```
        \\
        \\## > next
        \\
    ;
    const root = (try parseForTest(arena, src)).root;
    const doc = root.find("doc").?;
    // The heredoc block keeps its indented fence lines and runs to its real end...
    try testing.expectEqual(@as(usize, 2), doc.blocks.items.len);
    try testing.expect(std.mem.indexOf(u8, doc.blocks.items[0].code, "    code sample") != null);
    try testing.expect(std.mem.endsWith(u8, doc.blocks.items[0].code, "echo after\n"));
    // ...and a fenced block indented inside a list item opens and closes at its own indentation.
    try testing.expectEqualStrings("echo in list\n", doc.blocks.items[1].code);
    try testing.expect(root.find("next") != null);
}

test "a UTF-8 byte order mark does not hide the first heading" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = (try parseForTest(arena, "\xEF\xBB\xBF## > hi\n\n```sh\necho hi\n```\n")).root;
    try testing.expect(root.find("hi") != null);
}

test "a flag without a flags line gets a derived long name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\## > a
        \\
        \\**OPTIONS**
        \\* Watch_Mode
        \\    * desc: Rebuild on change
        \\* port
        \\    * flags: -p
        \\    * type: number
        \\
        \\```sh
        \\true
        \\```
        \\
        \\## Inline
        \\
        \\**OPTIONS**
        \\* dry_run
        \\
        \\```sh task
        \\true
        \\```
        \\
    ;
    const root = (try parseForTest(arena, src)).root;
    const a = root.find("a").?;
    try testing.expectEqualStrings("--watch-mode", a.flags.items[0].long.?);
    try testing.expectEqualStrings("-p", a.flags.items[1].short.?);
    try testing.expectEqualStrings("--port", a.flags.items[1].long.?);
    try testing.expectEqualStrings("--dry-run", root.find("inline").?.flags.items[0].long.?);
}
