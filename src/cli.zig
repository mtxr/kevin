//! Runtime CLI handling: command resolution, argument/flag parsing and
//! validation, and the dynamic `--help` generator.

const std = @import("std");
const ast = @import("ast.zig");
const Allocator = std.mem.Allocator;
const Command = ast.Command;
const Flag = ast.Flag;
const Io = std.Io;

pub const EnvPair = struct { name: []const u8, value: []const u8 };

pub const Invocation = struct {
    help: bool = false,
    verbose: bool = false,
    env: []const EnvPair = &.{},
    /// Flags that are absent or false: removed from the child's environment so a
    /// variable of the same name inherited from the caller cannot leak in.
    unset: []const []const u8 = &.{},
};

pub const Resolved = struct {
    cmd: *const Command,
    /// Names from the root to `cmd`.
    path: []const []const u8,
    /// Tokens left for the command's own args/flags.
    rest: []const []const u8,
};

fn isHelpTok(t: []const u8) bool {
    return std.mem.eql(u8, t, "-h") or std.mem.eql(u8, t, "--help");
}

fn isVerboseTok(t: []const u8) bool {
    return std.mem.eql(u8, t, "-v") or std.mem.eql(u8, t, "--verbose");
}

/// Walks `tokens` down the command tree. Implicit flags (-h/-v) found before
/// the final command are forwarded to it.
pub fn resolve(arena: Allocator, root: *const Command, tokens: []const []const u8) Allocator.Error!Resolved {
    var cur = root;
    var path: std.ArrayList([]const u8) = .empty;
    var early: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const t = tokens[i];
        if (isHelpTok(t) or isVerboseTok(t)) {
            try early.append(arena, t);
            continue;
        }
        if (t.len > 0 and t[0] == '-') break;
        const next = cur.find(t) orelse break;
        cur = next;
        try path.append(arena, t);
    }
    try early.appendSlice(arena, tokens[i..]);
    return .{ .cmd = cur, .path = path.items, .rest = early.items };
}

fn findLong(cmd: *const Command, name: []const u8) ?usize {
    for (cmd.flags.items, 0..) |f, i| {
        const long = f.long orelse continue;
        if (std.mem.eql(u8, long[2..], name)) return i;
    }
    return null;
}

fn findShort(cmd: *const Command, ch: u8) ?usize {
    for (cmd.flags.items, 0..) |f, i| {
        const s = f.short orelse continue;
        if (s.len == 2 and s[1] == ch) return i;
    }
    return null;
}

fn looksNumeric(s: []const u8) bool {
    _ = std.fmt.parseFloat(f64, s) catch return false;
    return true;
}

/// On failure returns `error.Usage` and sets `err_msg`.
pub fn parseInvocation(
    arena: Allocator,
    cmd: *const Command,
    tokens: []const []const u8,
    err_msg: *[]const u8,
) (Allocator.Error || error{Usage})!Invocation {
    var inv: Invocation = .{};
    const flags = cmd.flags.items;
    const values = try arena.alloc(?[]const u8, flags.len);
    @memset(values, null);
    var positionals: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    var only_positional = false;
    while (i < tokens.len) : (i += 1) {
        const tok = tokens[i];
        if (only_positional or tok.len < 2 or tok[0] != '-') {
            try positionals.append(arena, tok);
            continue;
        }
        if (std.mem.eql(u8, tok, "--")) {
            only_positional = true;
            continue;
        }

        if (std.mem.startsWith(u8, tok, "--")) {
            const body = tok[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;
            const inline_val: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;
            if (findLong(cmd, name)) |fi| {
                try setFlag(arena, &values[fi], flags[fi], inline_val, tokens, &i, err_msg);
            } else if (std.mem.eql(u8, name, "help")) {
                inv.help = true;
            } else if (std.mem.eql(u8, name, "verbose")) {
                inv.verbose = true;
            } else {
                err_msg.* = try std.fmt.allocPrint(arena, "unknown flag '--{s}'", .{name});
                return error.Usage;
            }
            continue;
        }

        // Negative numbers are positionals when no short flag claims them.
        if (looksNumeric(tok) and findShort(cmd, tok[1]) == null) {
            try positionals.append(arena, tok);
            continue;
        }

        // Short flag cluster: -abc, -p8080, -p=8080, -p 8080
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            const ch = tok[j];
            if (findShort(cmd, ch)) |fi| {
                const f = flags[fi];
                if (f.ftype == .boolean) {
                    values[fi] = "true";
                    continue;
                }
                var rest: ?[]const u8 = null;
                if (j + 1 < tok.len) {
                    rest = tok[j + 1 ..];
                    if (rest.?[0] == '=') rest = rest.?[1..];
                }
                try setFlag(arena, &values[fi], f, rest, tokens, &i, err_msg);
                break;
            } else if (ch == 'h') {
                inv.help = true;
            } else if (ch == 'v') {
                inv.verbose = true;
            } else {
                err_msg.* = try std.fmt.allocPrint(arena, "unknown flag '-{c}'", .{ch});
                return error.Usage;
            }
        }
    }

    if (inv.help) return inv;

    const args = cmd.args.items;
    if (positionals.items.len > args.len) {
        err_msg.* = try std.fmt.allocPrint(arena, "unexpected argument '{s}'", .{positionals.items[args.len]});
        return error.Usage;
    }

    var env: std.ArrayList(EnvPair) = .empty;
    var unset: std.ArrayList([]const u8) = .empty;
    for (args, 0..) |a, idx| {
        if (idx < positionals.items.len) {
            try env.append(arena, .{ .name = a.name, .value = positionals.items[idx] });
        } else if (a.required) {
            err_msg.* = try std.fmt.allocPrint(arena, "missing required argument <{s}>", .{a.name});
            return error.Usage;
        } else {
            // An absent optional argument is empty, so a variable of the same name
            // inherited from the caller (or from a task calling `$KEVIN`) cannot leak in.
            try env.append(arena, .{ .name = a.name, .value = "" });
        }
    }

    for (flags, values) |f, maybe| {
        const v = maybe orelse {
            if (f.required) {
                err_msg.* = try std.fmt.allocPrint(arena, "missing required flag {s}", .{flagLabel(f)});
                return error.Usage;
            }
            try unset.append(arena, f.name);
            continue;
        };
        switch (f.ftype) {
            .number => {
                _ = std.fmt.parseFloat(f64, v) catch {
                    err_msg.* = try std.fmt.allocPrint(arena, "invalid value '{s}' for {s}: expected a number", .{ v, flagLabel(f) });
                    return error.Usage;
                };
            },
            .boolean => {
                if (std.mem.eql(u8, v, "false")) { // `--flag=false` behaves as absent
                    try unset.append(arena, f.name);
                    continue;
                }
            },
            .string => {},
        }
        if (f.choices.len > 0) {
            for (f.choices) |c| {
                if (std.mem.eql(u8, c, v)) break;
            } else {
                err_msg.* = try std.fmt.allocPrint(arena, "invalid value '{s}' for {s}: expected one of {s}", .{
                    v, flagLabel(f), try std.mem.join(arena, ", ", f.choices),
                });
                return error.Usage;
            }
        }
        try env.append(arena, .{ .name = f.name, .value = v });
    }

    inv.env = env.items;
    inv.unset = unset.items;
    return inv;
}

fn setFlag(
    arena: Allocator,
    slot: *?[]const u8,
    f: Flag,
    inline_val: ?[]const u8,
    tokens: []const []const u8,
    i: *usize,
    err_msg: *[]const u8,
) (Allocator.Error || error{Usage})!void {
    if (f.ftype == .boolean) {
        slot.* = inline_val orelse "true";
        return;
    }
    if (inline_val) |v| {
        slot.* = v;
        return;
    }
    if (i.* + 1 >= tokens.len) {
        err_msg.* = try std.fmt.allocPrint(arena, "flag {s} requires a value", .{flagLabel(f)});
        return error.Usage;
    }
    i.* += 1;
    slot.* = tokens[i.*];
}

fn flagLabel(f: Flag) []const u8 {
    return f.long orelse f.short orelse f.name;
}

// --------------------------------------------------------------------- help

const Row = struct { left: []const u8, right: []const u8 };

fn printRows(w: *Io.Writer, rows: []const Row) Io.Writer.Error!void {
    var width: usize = 0;
    for (rows) |r| width = @max(width, r.left.len);
    for (rows) |r| {
        try w.print("  {s}", .{r.left});
        if (r.right.len > 0) {
            try w.splatByteAll(' ', width - r.left.len + 2);
            try w.writeAll(r.right);
        }
        try w.writeByte('\n');
    }
}

fn argSignature(arena: Allocator, cmd: *const Command) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (cmd.args.items) |a| {
        try out.appendSlice(arena, if (a.required) " <" else " [");
        try out.appendSlice(arena, a.name);
        try out.append(arena, if (a.required) '>' else ']');
    }
    return out.items;
}

fn collectCommandRows(
    arena: Allocator,
    cmd: *const Command,
    prefix: []const u8,
    rows: *std.ArrayList(Row),
    recursive: bool,
) Allocator.Error!void {
    for (cmd.children.items) |c| {
        const name = if (prefix.len == 0) c.name else try std.fmt.allocPrint(arena, "{s} {s}", .{ prefix, c.name });
        const left = try std.fmt.allocPrint(arena, "{s}{s}", .{ name, try argSignature(arena, c) });
        try rows.append(arena, .{ .left = left, .right = c.description });
        if (recursive) try collectCommandRows(arena, c, name, rows, true);
    }
}

pub fn printRootHelp(arena: Allocator, w: *Io.Writer, root: *const Command, sources: []const []const u8) (Allocator.Error || Io.Writer.Error)!void {
    try w.writeAll("kevin - run tasks declared in Markdown files\n\n");
    try w.writeAll("Usage: kevin [OPTIONS] <COMMAND> [ARGS]...\n\n");
    if (sources.len > 0) {
        try w.writeAll("Sources:\n");
        for (sources) |s| try w.print("  {s}\n", .{s});
        try w.writeByte('\n');
    }
    if (root.children.items.len == 0) {
        try w.writeAll("No commands found.\n\n");
    } else {
        var rows: std.ArrayList(Row) = .empty;
        try collectCommandRows(arena, root, "", &rows, true);
        try w.writeAll("Commands:\n");
        try printRows(w, rows.items);
        try w.writeByte('\n');
    }
    try w.writeAll("Options:\n");
    try printRows(w, &.{
        .{ .left = "-f, --file <PATH>", .right = "Use a specific Markdown file" },
        .{ .left = "    --from <mask|xc>", .right = "Convert a mask/xc file to kevin syntax (stdout, or -o)" },
        .{ .left = "-o, --output <PATH>", .right = "With --from: write the result to a new file" },
        .{ .left = "-j, --jobs <N>", .right = "Max scripts running at once (default: CPU count, or $KEVIN_JOBS)" },
        .{ .left = "    --completion <shell>", .right = "Print a completion script (zsh, bash or fish): eval \"$(kevin --completion zsh)\"" },
        .{ .left = "    --check-update", .right = "Check whether a newer release exists (downloads nothing)" },
        .{ .left = "    --introspect", .right = "Print the command tree as JSON" },
        .{ .left = "    --explain", .right = "Show how the command resolves and what would run, without running it" },
        .{ .left = "-V, --version", .right = "Print the kevin version" },
        .{ .left = "-h, --help", .right = "Print help" },
        .{ .left = "-v, --verbose", .right = "Echo each code block before running it" },
    });
}

pub fn printCommandHelp(arena: Allocator, w: *Io.Writer, cmd: *const Command, path: []const []const u8) (Allocator.Error || Io.Writer.Error)!void {
    const joined = try std.mem.join(arena, " ", path);
    try w.print("Usage: kevin {s}{s}", .{ joined, try argSignature(arena, cmd) });
    if (cmd.children.items.len > 0 and !cmd.hasWork()) try w.writeAll(" <COMMAND>");
    try w.writeAll(" [OPTIONS]\n");
    if (cmd.description.len > 0) try w.print("\n{s}\n", .{cmd.description});
    if (cmd.deps.requires.items.len > 0) {
        try w.writeAll("\nRequires: ");
        for (cmd.deps.requires.items, 0..) |r, i| try w.print("{s}{s}", .{ if (i > 0) ", " else "", r });
        try w.print(" ({s}", .{if (cmd.deps.run_deps == .async) "async" else "sync"});
        if (cmd.deps.jobs) |j| try w.print(", at most {d} at once", .{j});
        if (cmd.deps.run_once) try w.writeAll(", once per run");
        try w.writeAll(")\n");
    }

    if (cmd.args.items.len > 0) {
        try w.writeAll("\nArguments:\n");
        var rows: std.ArrayList(Row) = .empty;
        for (cmd.args.items) |a| {
            const left = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{
                if (a.required) "<" else "[", a.name, if (a.required) ">" else "]",
            });
            try rows.append(arena, .{ .left = left, .right = if (a.required) "required" else "optional" });
        }
        try printRows(w, rows.items);
    }

    try w.writeAll("\nOptions:\n");
    var rows: std.ArrayList(Row) = .empty;
    for (cmd.flags.items) |f| {
        var left: std.ArrayList(u8) = .empty;
        if (f.short) |s| {
            try left.appendSlice(arena, s);
            try left.appendSlice(arena, ", ");
        } else try left.appendSlice(arena, "    ");
        try left.appendSlice(arena, f.long orelse try std.fmt.allocPrint(arena, "--{s}", .{f.name}));
        if (f.ftype != .boolean) {
            try left.appendSlice(arena, " <");
            try left.appendSlice(arena, f.ftype.label());
            try left.append(arena, '>');
        }
        var right: std.ArrayList(u8) = .empty;
        try right.appendSlice(arena, f.desc);
        if (f.choices.len > 0) {
            try right.print(arena, " [choices: {s}]", .{try std.mem.join(arena, ", ", f.choices)});
        }
        if (f.required) try right.appendSlice(arena, " (required)");
        try rows.append(arena, .{ .left = left.items, .right = std.mem.trim(u8, right.items, " ") });
    }
    try rows.append(arena, .{ .left = "-h, --help", .right = "Print help" });
    try rows.append(arena, .{ .left = "-v, --verbose", .right = "Echo each code block before running it" });
    try printRows(w, rows.items);

    if (cmd.children.items.len > 0) {
        var crow: std.ArrayList(Row) = .empty;
        try collectCommandRows(arena, cmd, "", &crow, false);
        try w.writeAll("\nCommands:\n");
        try printRows(w, crow.items);
    }
}

// -------------------------------------------------------------------- tests

const testing = std.testing;
const parser = @import("parser.zig");

const sample =
    \\## > serve (target) [extra]
    \\> Serve things
    \\
    \\**OPTIONS**
    \\* port
    \\    * flags: -p --port
    \\    * type: number
    \\    * required
    \\* env
    \\    * flags: -e --env
    \\    * type: string
    \\    * choices: dev, prod
    \\* watch
    \\    * flags: -w --watch
    \\
    \\```bash
    \\true
    \\```
    \\
    \\### > sub
    \\
    \\```bash
    \\true
    \\```
    \\
;

fn lookup(inv: Invocation, name: []const u8) ?[]const u8 {
    for (inv.env) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
    return null;
}

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

test "absent and false flags are listed as unset" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = (try parser.parseSource(arena, "/x.md", sample)).root;
    const cmd = root.find("serve").?;
    var msg: []const u8 = "";

    const none = try parseInvocation(arena, cmd, &.{ "web", "-p", "1" }, &msg);
    try testing.expect(inList(none.unset, "env"));
    try testing.expect(inList(none.unset, "watch"));
    try testing.expect(!inList(none.unset, "port"));

    const set = try parseInvocation(arena, cmd, &.{ "web", "-p", "1", "-w", "-e", "dev" }, &msg);
    try testing.expectEqual(@as(usize, 0), set.unset.len);

    const off = try parseInvocation(arena, cmd, &.{ "web", "-p", "1", "--watch=false" }, &msg);
    try testing.expect(inList(off.unset, "watch"));
    try testing.expect(lookup(off, "watch") == null);
}

test "resolve nested commands and parse args/flags" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = (try parser.parseSource(arena, "/x.md", sample)).root;

    const r = try resolve(arena, root, &.{ "serve", "web", "-p", "8080", "--env=dev", "-w" });
    try testing.expectEqualStrings("serve", r.cmd.name);
    var msg: []const u8 = "";
    const inv = try parseInvocation(arena, r.cmd, r.rest, &msg);
    try testing.expectEqualStrings("web", lookup(inv, "target").?);
    try testing.expectEqualStrings("", lookup(inv, "extra").?);
    try testing.expectEqualStrings("8080", lookup(inv, "port").?);
    try testing.expectEqualStrings("dev", lookup(inv, "env").?);
    try testing.expectEqualStrings("true", lookup(inv, "watch").?);

    const sub = try resolve(arena, root, &.{ "serve", "sub" });
    try testing.expectEqualStrings("sub", sub.cmd.name);
    try testing.expectEqual(@as(usize, 2), sub.path.len);
}

test "validation errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = (try parser.parseSource(arena, "/x.md", sample)).root;
    const serve = root.find("serve").?;
    var msg: []const u8 = "";

    try testing.expectError(error.Usage, parseInvocation(arena, serve, &.{ "web", "-p", "abc" }, &msg));
    try testing.expect(std.mem.indexOf(u8, msg, "expected a number") != null);

    try testing.expectError(error.Usage, parseInvocation(arena, serve, &.{ "web", "-p", "1", "-e", "qa" }, &msg));
    try testing.expect(std.mem.indexOf(u8, msg, "expected one of dev, prod") != null);

    try testing.expectError(error.Usage, parseInvocation(arena, serve, &.{"web"}, &msg));
    try testing.expect(std.mem.indexOf(u8, msg, "missing required flag --port") != null);

    try testing.expectError(error.Usage, parseInvocation(arena, serve, &.{ "-p", "1" }, &msg));
    try testing.expect(std.mem.indexOf(u8, msg, "missing required argument <target>") != null);

    try testing.expectError(error.Usage, parseInvocation(arena, serve, &.{ "a", "-p", "1", "--nope" }, &msg));
    try testing.expectError(error.Usage, parseInvocation(arena, serve, &.{ "a", "b", "c", "-p", "1" }, &msg));

    // Floats and negatives are valid numbers; `--` stops flag parsing.
    const inv = try parseInvocation(arena, serve, &.{ "--port=-1.5", "--", "-x" }, &msg);
    try testing.expectEqualStrings("-1.5", lookup(inv, "port").?);
    try testing.expectEqualStrings("-x", lookup(inv, "target").?);
}

test "implicit flags and help text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = (try parser.parseSource(arena, "/x.md", sample)).root;
    const serve = root.find("serve").?;
    var msg: []const u8 = "";

    const inv = try parseInvocation(arena, serve, &.{ "-v", "web", "-p", "1" }, &msg);
    try testing.expect(inv.verbose and !inv.help);
    const h = try parseInvocation(arena, serve, &.{"--help"}, &msg);
    try testing.expect(h.help);

    var aw: Io.Writer.Allocating = .init(arena);
    try printCommandHelp(arena, &aw.writer, serve, &.{"serve"});
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "Usage: kevin serve <target> [extra]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "-p, --port <NUMBER>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[choices: dev, prod]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "sub") != null);

    var aw2: Io.Writer.Allocating = .init(arena);
    try printRootHelp(arena, &aw2.writer, root, &.{});
    try testing.expect(std.mem.indexOf(u8, aw2.written(), "serve sub") != null);
}

test "a flag declared without flags: is accepted by its derived name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\## > a
        \\
        \\**OPTIONS**
        \\* watch_mode
        \\    * desc: Rebuild on change
        \\
        \\```sh
        \\true
        \\```
        \\
    ;
    const root = (try parser.parseSource(arena, "/x.md", src)).root;
    const a = root.find("a").?;
    var msg: []const u8 = "";
    const inv = try parseInvocation(arena, a, &.{"--watch-mode"}, &msg);
    try testing.expectEqualStrings("true", lookup(inv, "watch_mode").?);

    var aw: Io.Writer.Allocating = .init(arena);
    try printCommandHelp(arena, &aw.writer, a, &.{"a"});
    try testing.expect(std.mem.indexOf(u8, aw.written(), "--watch-mode") != null);
}
