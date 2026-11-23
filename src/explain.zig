//! `kevin --explain`: shows how a command was resolved and what would run,
//! without running anything.

const std = @import("std");
const ast = @import("ast.zig");
const cli = @import("cli.zig");
const runner = @import("runner.zig");
const deps = @import("deps.zig");
const Io = std.Io;
const Command = ast.Command;

pub const Info = struct {
    sources: []const []const u8,
    warnings: []const []const u8,
    cmd: *const Command,
    /// Names from the root to `cmd`.
    path: []const []const u8,
    invocation: cli.Invocation,
    /// Set when argument/flag validation failed.
    usage_error: ?[]const u8,
    /// Variables kevin adds on top of the inherited environment.
    injected: []const cli.EnvPair,
    steps: []const runner.Step,
    /// Resolved dependency tree (null when validation failed).
    graph: ?*const deps.Node = null,
    jobs: usize = 0,
};

fn lookup(pairs: []const cli.EnvPair, name: []const u8) ?[]const u8 {
    for (pairs) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
    return null;
}

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn writeArg(w: *Io.Writer, arg: []const u8, code: []const u8) Io.Writer.Error!void {
    if (std.mem.eql(u8, arg, code) and code.len > 0) {
        try w.writeAll("<code>");
    } else if (arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t'\"") != null) {
        try w.print("'{s}'", .{arg});
    } else {
        try w.writeAll(arg);
    }
}

fn printTree(w: *Io.Writer, node: *const deps.Node, depth: usize) Io.Writer.Error!void {
    if (node.deps.len == 0) return;
    for (node.deps) |d| {
        try w.splatByteAll(' ', depth * 2);
        try w.print("{s}", .{d.cmd.name});
        for (d.env) |p| try w.print(" {s}={s}", .{ p.name, p.value });
        try w.print("  [{s}{s}]\n", .{ if (node.async_deps) "async" else "sync", if (d.once) ", once" else "" });
        try printTree(w, d, depth + 1);
    }
}

pub fn print(w: *Io.Writer, info: Info) Io.Writer.Error!void {
    const cmd = info.cmd;

    try w.writeAll("Sources\n");
    for (info.sources, 1..) |s, i| try w.print("  {d}. {s}\n", .{ i, s });
    for (info.warnings) |warn| try w.print("  warning: {s}\n", .{warn});

    try w.writeAll("\nCommand\n");
    if (info.path.len == 0) {
        try w.writeAll("  path:        (root)\n");
    } else {
        try w.writeAll("  path:        ");
        for (info.path, 0..) |p, i| try w.print("{s}{s}", .{ if (i > 0) " " else "", p });
        try w.writeByte('\n');
    }
    if (cmd.source_path.len > 0) try w.print("  declared in: {s}:{d}\n", .{ cmd.source_path, cmd.decl_line });
    if (cmd.description.len > 0) try w.print("  description: {s}\n", .{cmd.description});

    if (cmd.args.items.len > 0) {
        try w.writeAll("\nArguments\n");
        for (cmd.args.items) |a| {
            try w.print("  {s} ({s}) = ", .{ a.name, if (a.required) "required" else "optional" });
            if (lookup(info.invocation.env, a.name)) |v| {
                if (v.len == 0) try w.writeAll("(empty)\n") else try w.print("{s}\n", .{v});
            } else try w.writeAll("(not set)\n");
        }
    }

    if (cmd.flags.items.len > 0) {
        try w.writeAll("\nFlags\n");
        for (cmd.flags.items) |f| {
            try w.print("  {s}", .{f.long orelse f.name});
            if (f.short) |s| try w.print(" {s}", .{s});
            try w.print("  {t}", .{f.ftype});
            if (f.required) try w.writeAll("  required");
            if (f.choices.len > 0) {
                try w.writeAll("  choices: ");
                for (f.choices, 0..) |c, i| try w.print("{s}{s}", .{ if (i > 0) ", " else "", c });
            }
            try w.print("  env: {s} = ", .{f.name});
            if (lookup(info.invocation.env, f.name)) |v| {
                try w.print("{s}\n", .{v});
            } else if (inList(info.invocation.unset, f.name)) {
                try w.writeAll("(unset: not inherited from the environment)\n");
            } else try w.writeAll("(not set)\n");
        }
    }

    if (info.path.len == 0) {
        try w.writeAll("\nNo command given: kevin would print the root help.\n");
        return;
    }

    try w.writeAll("\nValidation\n");
    if (info.usage_error) |msg| {
        try w.print("  FAILED: {s}\n", .{msg});
        return;
    }
    try w.writeAll("  ok\n");

    if (info.graph) |g| {
        if (g.deps.len > 0) {
            try w.print("\nDependencies (max {d} scripts at once)\n", .{info.jobs});
            try printTree(w, g, 1);
        }
    }

    try w.writeAll("\nEnvironment added by kevin\n");
    for (info.injected) |p| try w.print("  {s}={s}\n", .{ p.name, p.value });

    try w.print("\nBlocks ({d})\n", .{info.steps.len});
    if (info.steps.len == 0) try w.writeAll("  (none: kevin would print help for this command)\n");
    for (info.steps, 1..) |st, i| {
        const b = st.block;
        const lang = if (b.lang.len == 0) "(none)" else b.lang;
        try w.print("  {d}. {s}  {s}:{d}  ->  ", .{ i, lang, cmd.source_path, b.line });
        switch (st.status) {
            .skipped => {
                try w.print("skipped ({s})\n", .{st.reason});
                continue;
            },
            .no_runtime => {
                try w.writeAll("NO RUNTIME (tried: ");
                for (st.tried, 0..) |t, k| try w.print("{s}{s}", .{ if (k > 0) ", " else "", t });
                try w.writeAll(")\n");
            },
            .run => try w.writeAll("run\n"),
        }
        if (st.launch) |l| {
            try w.writeAll("       runtime: ");
            for (st.tried, 0..) |t, k| {
                if (k > 0) try w.writeAll(" (not found), ");
                try w.writeAll(t);
            }
            try w.writeAll("\n       argv:    ");
            for (l.argv, 0..) |a, k| {
                if (k > 0) try w.writeByte(' ');
                try writeArg(w, a, b.code);
            }
            try w.writeByte('\n');
            if (l.stdin != null) try w.writeAll("       stdin:   <code>\n");
        }
        try w.writeAll("       code:\n");
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, b.code, "\n"), '\n');
        while (it.next()) |line| try w.print("         | {s}\n", .{line});
    }
}

const testing = std.testing;
const parser = @import("parser.zig");

test "explain prints source, validation and per-block decisions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\## > serve (target)
        \\> Serve things
        \\
        \\**OPTIONS**
        \\* port
        \\    * flags: -p --port
        \\    * type: number
        \\
        \\```bash
        \\echo "$target:$port"
        \\```
        \\
        \\```json
        \\{}
        \\```
        \\
    ;
    const root = (try parser.parseSource(arena, "/x/tasks.md", src)).root;
    const cmd = root.find("serve").?;
    var msg: []const u8 = "";
    const inv = try cli.parseInvocation(arena, cmd, &.{ "web", "-p", "80" }, &msg);

    var env = std.process.Environ.Map.init(arena);
    const steps = try runner.planFor(arena, testing.io, cmd, &env, .linux);
    var aw: Io.Writer.Allocating = .init(arena);
    try print(&aw.writer, .{
        .sources = &.{"/x/tasks.md"},
        .warnings = &.{},
        .cmd = cmd,
        .path = &.{"serve"},
        .invocation = inv,
        .usage_error = null,
        .injected = inv.env,
        .steps = steps,
    });
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "declared in: /x/tasks.md:1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "target (required) = web") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--port -p  number  env: port = 80") != null);
    try testing.expect(std.mem.indexOf(u8, out, "NO RUNTIME (tried: bash)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "skipped ('json' is not an executable language)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "| echo \"$target:$port\"") != null);

    var aw2: Io.Writer.Allocating = .init(arena);
    try print(&aw2.writer, .{
        .sources = &.{},
        .warnings = &.{},
        .cmd = cmd,
        .path = &.{"serve"},
        .invocation = .{},
        .usage_error = "missing required argument <target>",
        .injected = &.{},
        .steps = &.{},
    });
    try testing.expect(std.mem.indexOf(u8, aw2.written(), "FAILED: missing required argument <target>") != null);
}

test "explain shows example blocks as skipped and absent flags as unset" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\## > demo
        \\
        \\**OPTIONS**
        \\* quiet
        \\
        \\```sh
        \\echo one
        \\```
        \\
        \\For example:
        \\
        \\```sh
        \\demo --quiet
        \\```
        \\
    ;
    const root = (try parser.parseSource(arena, "/x/tasks.md", src)).root;
    const cmd = root.find("demo").?;
    var msg: []const u8 = "";
    const inv = try cli.parseInvocation(arena, cmd, &.{}, &msg);
    var env = std.process.Environ.Map.init(arena);
    const steps = try runner.planFor(arena, testing.io, cmd, &env, .linux);
    var aw: Io.Writer.Allocating = .init(arena);
    try print(&aw.writer, .{
        .sources = &.{"/x/tasks.md"},
        .warnings = &.{},
        .cmd = cmd,
        .path = &.{"demo"},
        .invocation = inv,
        .usage_error = null,
        .injected = inv.env,
        .steps = steps,
    });
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "env: quiet = (unset") != null);
    try testing.expect(std.mem.indexOf(u8, out, "skipped (example:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "add `task`") != null);
}
