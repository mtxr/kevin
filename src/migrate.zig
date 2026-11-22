//! Converts mask (`maskfile.md`) and xc (`README.md` with a `Tasks` section)
//! files into kevin syntax. The conversion keeps all non-command prose
//! untouched and reports everything it could not translate as notes.

const std = @import("std");
const parser = @import("parser.zig");
const runner = @import("runner.zig");
const Allocator = std.mem.Allocator;

pub const Source = enum {
    mask,
    xc,

    pub fn parse(s: []const u8) ?Source {
        if (std.ascii.eqlIgnoreCase(s, "mask")) return .mask;
        if (std.ascii.eqlIgnoreCase(s, "xc")) return .xc;
        return null;
    }

    /// File read when `--file` is not given.
    pub fn defaultFile(self: Source) []const u8 {
        return switch (self) {
            .mask => "maskfile.md",
            .xc => "README.md",
        };
    }
};

pub const Result = struct {
    output: []const u8,
    /// Things that need a human look.
    notes: []const []const u8,
};

pub const Error = error{NoTasksSection} || Allocator.Error;

pub fn migrate(arena: Allocator, source: Source, raw: []const u8) Error!Result {
    const no_bom = if (std.mem.startsWith(u8, raw, "\xEF\xBB\xBF")) raw[3..] else raw;
    const text = if (std.mem.indexOfScalar(u8, no_bom, '\r') != null)
        try std.mem.replaceOwned(u8, arena, no_bom, "\r\n", "\n")
    else
        no_bom;

    var lines_list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines_list.append(arena, l);
    // A trailing newline produces one empty last element; drop it and re-add on output.
    const had_trailing_newline = text.len > 0 and text[text.len - 1] == '\n';
    if (had_trailing_newline) _ = lines_list.pop();
    const lines = lines_list.items;
    const kinds = try classify(arena, lines);

    var notes: std.ArrayList([]const u8) = .empty;
    var open_line: ?usize = null;
    for (kinds, 0..) |k, i| switch (k) {
        .fence_open => open_line = i + 1,
        .fence_close => open_line = null,
        else => {},
    };
    if (open_line) |l| try note(arena, &notes, "the code block opened on line {d} is not ended; it was kept as is", .{l});

    var out: std.ArrayList(u8) = .empty;
    switch (source) {
        .mask => try migrateMask(arena, lines, kinds, &out, &notes),
        .xc => try migrateXc(arena, lines, kinds, &out, &notes),
    }
    if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') {
        if (had_trailing_newline or out.items.len > 0) try out.append(arena, '\n');
    }
    return .{ .output = out.items, .notes = notes.items };
}

// ------------------------------------------------------------------ shared

const LineKind = enum { text, fence_open, code, fence_close };

fn classify(arena: Allocator, lines: []const []const u8) Allocator.Error![]LineKind {
    const kinds = try arena.alloc(LineKind, lines.len);
    var in_fence = false;
    var ch: u8 = 0;
    var len: usize = 0;
    var indent: usize = 0;
    for (lines, kinds) |line, *k| {
        if (!in_fence) {
            if (parser.parseFence(line)) |f| {
                in_fence = true;
                ch = f.ch;
                len = f.len;
                indent = f.indent;
                k.* = .fence_open;
            } else k.* = .text;
        } else if (parser.isClosingFence(line, ch, len, indent)) {
            in_fence = false;
            k.* = .fence_close;
        } else k.* = .code;
    }
    return kinds;
}

fn note(arena: Allocator, notes: *std.ArrayList([]const u8), comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    try notes.append(arena, try std.fmt.allocPrint(arena, fmt, args));
}

fn firstWord(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t");
    return t[0 .. std.mem.indexOfAny(u8, t, " \t") orelse t.len];
}

fn appendLine(arena: Allocator, out: *std.ArrayList(u8), line: []const u8) Allocator.Error!void {
    try out.appendSlice(arena, line);
    try out.append(arena, '\n');
}

const hashes = "######";

// -------------------------------------------------------------------- mask

const Frame = struct { level: u8, words: []const []const u8 };

fn migrateMask(
    arena: Allocator,
    lines: []const []const u8,
    kinds: []const LineKind,
    out: *std.ArrayList(u8),
    notes: *std.ArrayList([]const u8),
) Allocator.Error!void {
    var stack: [6]Frame = undefined;
    var sp: usize = 0;
    var rewrites: usize = 0;
    var executable = false;

    for (lines, kinds) |line, kind| {
        switch (kind) {
            .fence_open => {
                const lang = firstWord(parser.parseFence(line).?.info);
                executable = runner.kindOf(lang) != null;
                if (std.ascii.eqlIgnoreCase(lang, "swift")) {
                    try note(arena, notes, "swift code blocks are not supported by kevin and will be ignored when running", .{});
                }
                try appendLine(arena, out, line);
            },
            .code => try appendLine(arena, out, if (executable) try rewriteMaskLine(arena, line, &rewrites) else line),
            .fence_close => try appendLine(arena, out, line),
            .text => {
                const h = parser.parseHeading(line) orelse {
                    try appendLine(arena, out, line);
                    continue;
                };
                while (sp > 0 and stack[sp - 1].level >= h.level) sp -= 1;
                // Level 1 is the document title in mask; already-migrated headings are kept.
                if (h.level == 1 or (h.text.len > 0 and h.text[0] == '>')) {
                    try appendLine(arena, out, line);
                    continue;
                }
                const name_end = std.mem.indexOfAny(u8, h.text, "([") orelse h.text.len;
                const name_part = std.mem.trim(u8, h.text[0..name_end], " \t");
                const params = std.mem.trim(u8, h.text[name_end..], " \t");
                if (name_part.len == 0) {
                    try appendLine(arena, out, line);
                    continue;
                }

                var words: std.ArrayList([]const u8) = .empty;
                var wit = std.mem.tokenizeAny(u8, name_part, " \t");
                while (wit.next()) |w| try words.append(arena, w);

                // `### services start` under `## services` -> `start`.
                const parent: []const []const u8 = if (sp > 0) stack[sp - 1].words else &.{};
                var rest: []const []const u8 = words.items;
                if (parent.len > 0 and words.items.len > parent.len) {
                    var same = true;
                    for (parent, words.items[0..parent.len]) |a, b| {
                        if (!std.mem.eql(u8, a, b)) same = false;
                    }
                    if (same) rest = words.items[parent.len..];
                }
                var name: []const u8 = rest[0];
                if (rest.len > 1) {
                    name = try std.mem.join(arena, "-", rest);
                    try note(arena, notes, "heading '{s}' has several words and no matching parent; renamed to '{s}'", .{ name_part, name });
                }

                const full = try std.mem.concat(arena, []const u8, &.{ parent, rest });
                stack[sp] = .{ .level = h.level, .words = full };
                sp += 1;

                if (params.len > 0) {
                    try out.print(arena, "{s} > {s} {s}\n", .{ hashes[0..h.level], name, params });
                } else {
                    try out.print(arena, "{s} > {s}\n", .{ hashes[0..h.level], name });
                }
            },
        }
    }
    if (rewrites > 0) {
        try note(arena, notes, "rewrote {d} reference(s) to $MASK, $MASKFILE_DIR or `mask <command>` into $KEVIN / $KEVIN_DIR", .{rewrites});
    }
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn replaceVar(
    arena: Allocator,
    s: []const u8,
    name: []const u8,
    repl: []const u8,
    count: *usize,
) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '$') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '$') {
            const after = s[i + 1 ..];
            if (std.mem.startsWith(u8, after, name) and (after.len == name.len or !isIdentChar(after[name.len]))) {
                try out.print(arena, "${s}", .{repl});
                i += 1 + name.len;
                count.* += 1;
                continue;
            }
            if (std.mem.startsWith(u8, after, "{") and std.mem.startsWith(u8, after[1..], name) and
                after.len > name.len + 1 and after[name.len + 1] == '}')
            {
                try out.print(arena, "${{{s}}}", .{repl});
                i += 3 + name.len;
                count.* += 1;
                continue;
            }
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

/// True when `mask` at `pos` starts a shell command.
fn atCommandPosition(s: []const u8, pos: usize) bool {
    var j = pos;
    while (j > 0 and (s[j - 1] == ' ' or s[j - 1] == '\t')) j -= 1;
    if (j == 0) return true;
    if (std.mem.indexOfScalar(u8, "&|;(`", s[j - 1]) != null) return true;
    var k = j;
    while (k > 0 and std.ascii.isAlphabetic(s[k - 1])) k -= 1;
    const word = s[k..j];
    return std.mem.eql(u8, word, "then") or std.mem.eql(u8, word, "do") or std.mem.eql(u8, word, "else");
}

fn rewriteMaskLine(arena: Allocator, line: []const u8, count: *usize) Allocator.Error![]const u8 {
    var s = try replaceVar(arena, line, "MASKFILE_DIR", "KEVIN_DIR", count);
    s = try replaceVar(arena, s, "MASK", "KEVIN", count);
    if (std.mem.indexOf(u8, s, "mask") == null) return s;

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], "mask") and
            (i == 0 or !(isIdentChar(s[i - 1]) or s[i - 1] == '-' or s[i - 1] == '/' or s[i - 1] == '.' or s[i - 1] == '$')) and
            (i + 4 == s.len or s[i + 4] == ' ' or s[i + 4] == '\t') and
            atCommandPosition(s, i))
        {
            try out.appendSlice(arena, "$KEVIN");
            i += 4;
            count.* += 1;
            continue;
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

// ---------------------------------------------------------------------- xc

const EnvVar = struct { name: []const u8, value: []const u8 };

fn langFromShebang(line: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, line[2..], " \t");
    var tok = it.next() orelse return null;
    if (std.mem.eql(u8, std.fs.path.basename(tok), "env")) {
        while (it.next()) |t| {
            if (t.len > 0 and t[0] != '-') {
                tok = t;
                break;
            }
        } else return null;
    }
    const base = std.fs.path.basename(tok);
    const map = [_]struct { []const u8, []const u8 }{
        .{ "sh", "sh" },     .{ "bash", "bash" },  .{ "zsh", "zsh" },
        .{ "fish", "fish" }, .{ "node", "js" },    .{ "nodejs", "js" },
        .{ "ruby", "ruby" }, .{ "lua", "lua" },    .{ "php", "php" },
        .{ "pwsh", "pwsh" }, .{ "bun", "ts" },     .{ "tsx", "ts" },
        .{ "deno", "ts" },   .{ "ts-node", "ts" },
    };
    for (map) |m| if (std.mem.eql(u8, base, m[0])) return m[1];
    if (std.mem.startsWith(u8, base, "python")) return "python";
    return null;
}

fn isShellLang(lang: []const u8) bool {
    return std.ascii.eqlIgnoreCase(lang, "sh") or std.ascii.eqlIgnoreCase(lang, "bash") or
        std.ascii.eqlIgnoreCase(lang, "zsh") or std.ascii.eqlIgnoreCase(lang, "shell");
}

fn usesPositional(code: []const []const u8) bool {
    for (code) |l| {
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, l, i, '$')) |d| {
            i = d + 1;
            if (i >= l.len) break;
            var c = l[i];
            if (c == '{' and i + 1 < l.len) c = l[i + 1];
            if ((c >= '1' and c <= '9') or c == '@' or c == '*') return true;
        }
    }
    return false;
}

fn shellSingleQuote(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "'{s}'", .{try std.mem.replaceOwned(u8, arena, s, "'", "'\\''")});
}

fn shellDoubleEscape(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.mem.indexOfScalar(u8, "\"\\$`", c) != null) try out.append(arena, '\\');
        try out.append(arena, c);
    }
    return out.items;
}

fn splitList(arena: Allocator, s: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    var it = std.mem.tokenizeAny(u8, s, ", \t");
    while (it.next()) |t| try out.append(arena, t);
}

fn migrateXc(
    arena: Allocator,
    lines: []const []const u8,
    kinds: []const LineKind,
    out: *std.ArrayList(u8),
    notes: *std.ArrayList([]const u8),
) Error!void {
    // 1. Locate the `Tasks` heading (or the one marked with <!-- xc-heading -->).
    var tasks_idx: ?usize = null;
    var tasks_level: u8 = 0;
    var prev_text: []const u8 = "";
    for (lines, kinds, 0..) |line, kind, i| {
        if (kind != .text) continue;
        if (parser.parseHeading(line)) |h| {
            if (std.ascii.eqlIgnoreCase(h.text, "tasks") or std.mem.eql(u8, prev_text, "<!-- xc-heading -->")) {
                tasks_idx = i;
                tasks_level = h.level;
                break;
            }
        }
        const t = std.mem.trim(u8, line, " \t");
        if (t.len > 0) prev_text = t;
    }
    const start = tasks_idx orelse return error.NoTasksSection;

    // 2. End of the section: next heading of level <= tasks_level.
    var end: usize = lines.len;
    for (lines[start + 1 ..], kinds[start + 1 ..], start + 1..) |line, kind, i| {
        if (kind != .text) continue;
        if (parser.parseHeading(line)) |h| {
            if (h.level <= tasks_level) {
                end = i;
                break;
            }
        }
    }

    var i: usize = 0;
    while (i < lines.len) {
        const line = lines[i];
        const is_task_heading = i > start and i < end and kinds[i] == .text and blk: {
            const h = parser.parseHeading(line) orelse break :blk false;
            break :blk h.level == tasks_level + 1;
        };
        if (!is_task_heading) {
            try appendLine(arena, out, line);
            i += 1;
            continue;
        }

        // Task body ends at the next heading of level <= task level (or the section end).
        const level = tasks_level + 1;
        var task_end = end;
        for (lines[i + 1 .. end], kinds[i + 1 .. end], i + 1..) |l2, k2, j| {
            if (k2 != .text) continue;
            if (parser.parseHeading(l2)) |h2| {
                if (h2.level <= level) {
                    task_end = j;
                    break;
                }
            }
        }
        try convertXcTask(arena, lines, kinds, i, task_end, level, out, notes);
        i = task_end;
    }
}

fn convertXcTask(
    arena: Allocator,
    lines: []const []const u8,
    kinds: []const LineKind,
    head: usize,
    task_end: usize,
    level: u8,
    out: *std.ArrayList(u8),
    notes: *std.ArrayList([]const u8),
) Error!void {
    const title = parser.parseHeading(lines[head]).?.text;
    var name = firstWord(title);
    if (std.mem.indexOfAny(u8, title, " \t") != null) {
        name = try parser.slugify(arena, title);
        try note(arena, notes, "task '{s}' contains spaces, which xc does not allow; renamed to '{s}'", .{ title, name });
    }

    // Split the body into: attributes + prose, first code block, trailing text.
    var fence_open: ?usize = null;
    for (kinds[head + 1 .. task_end], head + 1..) |k, j| {
        if (k == .fence_open) {
            fence_open = j;
            break;
        }
    }
    const pre_end = fence_open orelse task_end;

    var requires: std.ArrayList([]const u8) = .empty;
    var inputs: std.ArrayList([]const u8) = .empty;
    var envs: std.ArrayList(EnvVar) = .empty;
    var dir: ?[]const u8 = null;
    var async_deps = false;
    var run_once = false;
    var prose: std.ArrayList([]const u8) = .empty;

    for (lines[head + 1 .. pre_end]) |l| {
        const attr = parser.parseAttr(l) orelse {
            try prose.append(arena, l);
            continue;
        };
        switch (attr.kind) {
            .requires => {
                // Entries are comma separated; each one is a task name plus its arguments.
                var it = std.mem.splitScalar(u8, attr.val, ',');
                while (it.next()) |e| {
                    const entry = parser.stripDecor(e);
                    if (entry.len > 0) try requires.append(arena, entry);
                }
            },
            .inputs => try splitList(arena, attr.val, &inputs),
            .directory => dir = attr.val,
            .env => {
                var it = std.mem.splitScalar(u8, attr.val, ',');
                while (it.next()) |pair| {
                    const pr = parser.stripDecor(pair);
                    if (pr.len == 0) continue;
                    const eq = std.mem.indexOfScalar(u8, pr, '=') orelse {
                        try note(arena, notes, "task '{s}': ignored Env entry '{s}' without '='", .{ name, pr });
                        continue;
                    };
                    try envs.append(arena, .{ .name = parser.stripDecor(pr[0..eq]), .value = parser.stripDecor(pr[eq + 1 ..]) });
                }
            },
            .run => run_once = std.ascii.eqlIgnoreCase(attr.val, "once"),
            .run_deps => async_deps = std.ascii.eqlIgnoreCase(attr.val, "async"),
            .interactive => {}, // deprecated in xc, no effect
            .jobs => try prose.append(arena, l), // not an xc attribute
        }
    }

    // Heading with parameters taken from Inputs; an Env default makes an input optional.
    try out.print(arena, "{s} > {s}", .{ hashes[0..level], name });
    for (inputs.items) |inp| {
        var has_default = false;
        for (envs.items) |e| if (std.mem.eql(u8, e.name, inp)) {
            has_default = true;
        };
        if (has_default) {
            try out.print(arena, " [{s}]", .{inp});
        } else {
            try out.print(arena, " ({s})", .{inp});
        }
    }
    try out.append(arena, '\n');

    // First prose paragraph becomes the description; the rest stays as text.
    var p: usize = 0;
    while (p < prose.items.len and std.mem.trim(u8, prose.items[p], " \t").len == 0) p += 1;
    const desc_start = p;
    while (p < prose.items.len and std.mem.trim(u8, prose.items[p], " \t").len != 0) p += 1;
    if (p > desc_start) {
        for (prose.items[desc_start..p]) |l| try out.print(arena, "> {s}\n", .{std.mem.trim(u8, l, " \t")});
    }
    try out.append(arena, '\n');
    var wrote_rest = false;
    for (prose.items[p..]) |l| {
        if (!wrote_rest and std.mem.trim(u8, l, " \t").len == 0) continue;
        wrote_rest = true;
        try appendLine(arena, out, l);
    }
    if (wrote_rest and std.mem.trim(u8, prose.items[prose.items.len - 1], " \t").len != 0) try out.append(arena, '\n');

    // Dependencies map onto kevin's own attributes.
    if (requires.items.len > 0) {
        try out.appendSlice(arena, "Requires: ");
        for (requires.items, 0..) |r, i| try out.print(arena, "{s}{s}", .{ if (i > 0) ", " else "", r });
        try out.append(arena, '\n');
        if (async_deps) try out.appendSlice(arena, "RunDeps: async\n");
    }
    if (run_once) try out.appendSlice(arena, "Run: once\n");
    if (requires.items.len > 0 or run_once) try out.append(arena, '\n');

    // The task script itself.
    var tail_start = task_end;
    if (fence_open) |fo| {
        const f = parser.parseFence(lines[fo]).?;
        var close: usize = task_end;
        for (kinds[fo + 1 .. task_end], fo + 1..) |k, j| {
            if (k == .fence_close) {
                close = j;
                break;
            }
        }
        var code = lines[fo + 1 .. close];
        var lang = firstWord(f.info);
        if (code.len > 0 and std.mem.startsWith(u8, code[0], "#!")) {
            if (langFromShebang(code[0])) |l| {
                if (lang.len == 0) lang = l;
            } else if (lang.len == 0) {
                try note(arena, notes, "task '{s}': unknown shebang '{s}'; the block was kept as sh", .{ name, code[0] });
            }
            code = code[1..];
        }
        // xc runs untagged blocks with bash, stopping at the first failing command.
        var implicit_bash = false;
        if (lang.len == 0) {
            lang = "bash";
            implicit_bash = true;
        }

        const shell = isShellLang(lang);
        const has_setup = dir != null or envs.items.len > 0;
        if (!shell and dir == null) {
            try note(arena, notes, "task '{s}': xc runs it in the Markdown file's directory; kevin runs this {s} block in the current directory (use $KEVIN_DIR)", .{ name, lang });
        }
        if (has_setup and !shell) {
            try note(arena, notes, "task '{s}': Directory/Env cannot be applied to a {s} block; set them manually", .{ name, lang });
        }
        if (usesPositional(code)) {
            try note(arena, notes, "task '{s}': the script uses positional parameters ($1, $@...); kevin passes arguments as named environment variables, so declare them as (name) in the heading", .{name});
        }

        try out.print(arena, "{s}{s}\n", .{ try fenceOf(arena, f), lang });
        if (shell) {
            if (implicit_bash) try out.appendSlice(arena, "set -e\n");
            // xc runs tasks in the Markdown file's directory unless `Directory:` says otherwise.
            if (dir) |d| {
                const dd = std.mem.trim(u8, d, " \t");
                if (!std.mem.eql(u8, dd, "$PWD")) {
                    const rel = if (std.mem.startsWith(u8, dd, "./")) dd[2..] else dd;
                    if (rel.len > 0 and (rel[0] == '/' or rel[0] == '~')) {
                        try out.print(arena, "cd \"{s}\"\n", .{try shellDoubleEscape(arena, rel)});
                    } else {
                        try out.print(arena, "cd \"$KEVIN_DIR/{s}\"\n", .{try shellDoubleEscape(arena, rel)});
                    }
                } else {
                    try note(arena, notes, "task '{s}': `Directory: $PWD` is already kevin's default", .{name});
                }
            } else {
                try out.appendSlice(arena, "cd \"$KEVIN_DIR\"\n");
            }
            for (envs.items) |e| {
                var is_input = false;
                for (inputs.items) |inp| if (std.mem.eql(u8, inp, e.name)) {
                    is_input = true;
                };
                if (is_input) {
                    try out.print(arena, "export {s}=\"${{{s}:-{s}}}\"\n", .{ e.name, e.name, try shellDoubleEscape(arena, e.value) });
                } else {
                    try out.print(arena, "export {s}={s}\n", .{ e.name, try shellSingleQuote(arena, e.value) });
                }
            }
        }
        for (code) |l| try appendLine(arena, out, l);
        if (close < task_end) {
            try appendLine(arena, out, lines[close]);
            tail_start = close + 1;
        } else {
            try appendLine(arena, out, try fenceOf(arena, f));
        }
    } else if (requires.items.len == 0) {
        try note(arena, notes, "task '{s}' has no commands (no script and no Requires)", .{name});
    } else if (dir != null or envs.items.len > 0) {
        try note(arena, notes, "task '{s}': Directory/Env were dropped because the task has no script", .{name});
    }

    for (lines[tail_start..task_end]) |l| try appendLine(arena, out, l);
}

/// Fence characters of the opening line (no info string).
fn fenceOf(arena: Allocator, f: parser.Fence) Allocator.Error![]const u8 {
    const buf = try arena.alloc(u8, f.len);
    @memset(buf, f.ch);
    return buf;
}

// -------------------------------------------------------------------- tests

const testing = std.testing;

test "mask: markers, prefix stripping and variables" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\# My maskfile
        \\
        \\## services
        \\
        \\> Manage services
        \\
        \\### services start (service_name)
        \\
        \\```bash
        \\echo "Starting $service_name from $MASKFILE_DIR"
        \\mask lint && mask format --check
        \\# mask is a comment here
        \\$MASK stop
        \\```
        \\
        \\### stop (service_name)
        \\
        \\````md
        \\## not a command
        \\````
        \\
    ;
    const res = try migrate(arena, .mask, src);
    try testing.expect(std.mem.indexOf(u8, res.output, "# My maskfile\n") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "## > services\n") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "### > start (service_name)\n") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "### > stop (service_name)\n") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "$KEVIN_DIR") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "$KEVIN lint && $KEVIN format --check") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "# mask is a comment here") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "$KEVIN stop") != null);
    // Headings inside fences are untouched.
    try testing.expect(std.mem.indexOf(u8, res.output, "\n## not a command\n") != null);
    try testing.expect(res.notes.len == 1);

    // The result is valid kevin input.
    const parsed = try parser.parseSource(arena, "/m.md", res.output);
    const services = parsed.root.find("services").?;
    try testing.expectEqualStrings("Manage services", services.description);
    try testing.expect(services.find("start") != null);
    try testing.expectEqual(@as(usize, 1), services.find("start").?.args.items.len);
}

test "xc: tasks, attributes, inputs, env and shebang" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\# Project
        \\
        \\Some intro.
        \\
        \\## Tasks
        \\
        \\### test
        \\
        \\Run the tests.
        \\
        \\```
        \\go test ./...
        \\```
        \\
        \\### deploy
        \\
        \\Deploy it.
        \\
        \\Requires: test, lint
        \\Directory: ./deployment
        \\Env: STAGE=prod
        \\Inputs: TARGET, NAME
        \\Env: NAME=World
        \\
        \\```
        \\sh deploy.sh
        \\```
        \\
        \\### py
        \\
        \\```
        \\#!/usr/bin/env python3
        \\print("hi")
        \\```
        \\
        \\## Other
        \\
        \\Not touched.
        \\
    ;
    const res = try migrate(arena, .xc, src);
    const o = res.output;
    try testing.expect(std.mem.indexOf(u8, o, "## Tasks\n") != null);
    try testing.expect(std.mem.indexOf(u8, o, "### > test\n> Run the tests.\n") != null);
    try testing.expect(std.mem.indexOf(u8, o, "### > deploy (TARGET) [NAME]\n> Deploy it.\n") != null);
    try testing.expect(std.mem.indexOf(u8, o, "Requires: test, lint\n") != null);
    try testing.expect(std.mem.indexOf(u8, o, "cd \"$KEVIN_DIR/deployment\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, o, "export STAGE='prod'\n") != null);
    try testing.expect(std.mem.indexOf(u8, o, "export NAME=\"${NAME:-World}\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, o, "```python\nprint(\"hi\")\n```") != null);
    try testing.expect(std.mem.indexOf(u8, o, "Not touched.") != null);
    // Inputs, Env, Directory and the description were consumed; Requires stays as a kevin attribute.
    try testing.expect(std.mem.indexOf(u8, o, "Inputs:") == null);
    try testing.expect(std.mem.indexOf(u8, o, "Directory:") == null);

    const parsed = try parser.parseSource(arena, "/x.md", o);
    const deploy = parsed.root.find("deploy").?;
    try testing.expectEqual(@as(usize, 2), deploy.args.items.len);
    try testing.expect(deploy.args.items[0].required);
    try testing.expect(!deploy.args.items[1].required);
    try testing.expectEqual(@as(usize, 1), deploy.blocks.items.len);
    try testing.expectEqual(@as(usize, 2), deploy.deps.requires.items.len);
    try testing.expectEqualStrings("python", parsed.root.find("py").?.blocks.items[0].lang);
    try testing.expectEqualStrings("bash", parsed.root.find("test").?.blocks.items[0].lang);
    try testing.expect(std.mem.indexOf(u8, o, "set -e\ncd \"$KEVIN_DIR\"\ngo test") != null);
}

test "xc: missing Tasks section and positional warning" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.NoTasksSection, migrate(arena, .xc, "# Nothing here\n"));

    const res = try migrate(arena, .xc, "## Tasks\n### greet\n```\necho $1\n```\n");
    var found = false;
    for (res.notes) |n| {
        if (std.mem.indexOf(u8, n, "positional") != null) found = true;
    }
    try testing.expect(found);
}
