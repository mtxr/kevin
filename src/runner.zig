//! Block selection (OS filtering), runtime mapping and process execution.

const std = @import("std");
const builtin = @import("builtin");
const ast = @import("ast.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const CodeBlock = ast.CodeBlock;
const Command = ast.Command;

pub const Kind = enum { sh, bash, zsh, fish, js, ts, py, ruby, lua, php, pwsh, bat };

const kinds = std.StaticStringMap(Kind).initComptime(.{
    .{ "sh", .sh },
    .{ "shell", .sh },
    .{ "bash", .bash },
    .{ "zsh", .zsh },
    .{ "fish", .fish },
    .{ "js", .js },
    .{ "javascript", .js },
    .{ "ts", .ts },
    .{ "typescript", .ts },
    .{ "py", .py },
    .{ "python", .py },
    .{ "ruby", .ruby },
    .{ "rb", .ruby },
    .{ "lua", .lua },
    .{ "php", .php },
    .{ "powershell", .pwsh },
    .{ "pwsh", .pwsh },
    .{ "bat", .bat },
    .{ "cmd", .bat },
});

/// Returns null for data blocks (json, yaml, text, md...) and blocks without a language.
pub fn kindOf(lang: []const u8) ?Kind {
    var buf: [16]u8 = undefined;
    if (lang.len == 0 or lang.len > buf.len) return null;
    return kinds.get(std.ascii.lowerString(&buf, lang));
}

const Family = enum { posix_shell, win_shell, other };

fn familyOf(k: Kind) Family {
    return switch (k) {
        .sh, .bash, .zsh, .fish => .posix_shell,
        .pwsh, .bat => .win_shell,
        else => .other,
    };
}

/// When both POSIX-shell and Windows-shell blocks exist, returns the family
/// that does not belong to `os` and must be dropped.
fn familyToDrop(blocks: []const CodeBlock, os: std.Target.Os.Tag) ?Family {
    var has_posix = false;
    var has_win = false;
    for (blocks) |b| {
        const k = kindOf(b.lang) orelse continue;
        switch (familyOf(k)) {
            .posix_shell => has_posix = true,
            .win_shell => has_win = true,
            .other => {},
        }
    }
    if (!(has_posix and has_win)) return null;
    return if (os == .windows) Family.posix_shell else Family.win_shell;
}

/// Drops non-executable blocks; when both POSIX-shell and Windows-shell
/// blocks exist, keeps only the family matching `os`. Order is preserved.
pub fn selectBlocks(arena: Allocator, blocks: []const CodeBlock, os: std.Target.Os.Tag) Allocator.Error![]const CodeBlock {
    const drop = familyToDrop(blocks, os);
    var out: std.ArrayList(CodeBlock) = .empty;
    for (blocks) |b| {
        const k = kindOf(b.lang) orelse continue;
        if (drop != null and familyOf(k) == drop.?) continue;
        try out.append(arena, b);
    }
    return out.items;
}

pub const Launch = struct {
    argv: []const []const u8,
    /// When set, the code is piped to the child's stdin instead of argv.
    stdin: ?[]const u8 = null,
};

/// Ordered runtime candidates; the first one found in PATH is used.
pub fn candidates(arena: Allocator, kind: Kind, code: []const u8) Allocator.Error![]const Launch {
    const L = struct {
        fn a(al: Allocator, parts: []const []const u8) Allocator.Error!Launch {
            return .{ .argv = try al.dupe([]const u8, parts) };
        }
        fn s(al: Allocator, parts: []const []const u8) Allocator.Error!Launch {
            return .{ .argv = try al.dupe([]const u8, parts), .stdin = "" };
        }
    };
    var out: std.ArrayList(Launch) = .empty;
    switch (kind) {
        .sh => try out.append(arena, try L.a(arena, &.{ "sh", "-c", code })),
        .bash => try out.append(arena, try L.a(arena, &.{ "bash", "-c", code })),
        .zsh => try out.append(arena, try L.a(arena, &.{ "zsh", "-c", code })),
        .fish => try out.append(arena, try L.a(arena, &.{ "fish", "-c", code })),
        .js => {
            try out.append(arena, try L.a(arena, &.{ "node", "-e", code }));
            try out.append(arena, try L.a(arena, &.{ "bun", "-e", code }));
        },
        .ts => {
            var l = try L.s(arena, &.{ "bun", "run", "-" });
            l.stdin = code;
            try out.append(arena, l);
            try out.append(arena, try L.a(arena, &.{ "tsx", "-e", code }));
            var d = try L.s(arena, &.{ "deno", "run", "-" });
            d.stdin = code;
            try out.append(arena, d);
        },
        .py => {
            try out.append(arena, try L.a(arena, &.{ "uv", "run", "python", "-c", code }));
            try out.append(arena, try L.a(arena, &.{ "python3", "-c", code }));
            try out.append(arena, try L.a(arena, &.{ "python", "-c", code }));
        },
        .ruby => try out.append(arena, try L.a(arena, &.{ "ruby", "-e", code })),
        .lua => try out.append(arena, try L.a(arena, &.{ "lua", "-e", code })),
        .php => try out.append(arena, try L.a(arena, &.{ "php", "-r", code })),
        .pwsh => {
            try out.append(arena, try L.a(arena, &.{ "pwsh", "-Command", code }));
            try out.append(arena, try L.a(arena, &.{ "powershell", "-Command", code }));
        },
        .bat => try out.append(arena, try L.a(arena, &.{ "cmd", "/c", code })),
    }
    return out.items;
}

fn inPath(arena: Allocator, io: Io, env: *const std.process.Environ.Map, name: []const u8) bool {
    const path = env.get("PATH") orelse return false;
    var it = std.mem.tokenizeScalar(u8, path, std.fs.path.delimiter);
    const exts: []const []const u8 = if (builtin.os.tag == .windows) &.{ "", ".exe", ".cmd", ".bat" } else &.{""};
    while (it.next()) |dir| {
        for (exts) |ext| {
            const full = std.fmt.allocPrint(arena, "{s}{c}{s}{s}", .{ dir, std.fs.path.sep, name, ext }) catch return false;
            Io.Dir.accessAbsolute(io, full, .{ .execute = true }) catch continue;
            return true;
        }
    }
    return false;
}

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |c| c,
        .signal, .stopped => |s| blk: {
            const n: u32 = @intCast(@backingInt(s));
            break :blk @truncate(128 +| n);
        },
        .unknown => 1,
    };
}

pub const Status = enum {
    /// Will be executed with `launch`.
    run,
    /// Not executed; see `reason`.
    skipped,
    /// Executable block but none of the candidate runtimes is in PATH.
    no_runtime,
};

pub const Step = struct {
    block: CodeBlock,
    status: Status,
    reason: []const u8 = "",
    /// Runtime executables looked up in PATH, in order.
    tried: []const []const u8 = &.{},
    launch: ?Launch = null,
};

/// Decides, for every block of `cmd`, what would happen, without running anything.
pub fn planFor(
    arena: Allocator,
    io: Io,
    cmd: *const Command,
    env: *const std.process.Environ.Map,
    os: std.Target.Os.Tag,
) Allocator.Error![]const Step {
    const drop = familyToDrop(cmd.blocks.items, os);
    var steps: std.ArrayList(Step) = .empty;
    for (cmd.blocks.items) |b| {
        const kind = kindOf(b.lang) orelse {
            const reason = if (b.lang.len == 0)
                "no language"
            else
                try std.fmt.allocPrint(arena, "'{s}' is not an executable language", .{b.lang});
            try steps.append(arena, .{ .block = b, .status = .skipped, .reason = reason });
            continue;
        };
        if (drop != null and familyOf(kind) == drop.?) {
            const reason = try std.fmt.allocPrint(arena, "shell family of another OS (current OS: {t})", .{os});
            try steps.append(arena, .{ .block = b, .status = .skipped, .reason = reason });
            continue;
        }
        const cands = try candidates(arena, kind, b.code);
        var tried: std.ArrayList([]const u8) = .empty;
        var chosen: ?Launch = null;
        for (cands) |c| {
            try tried.append(arena, c.argv[0]);
            if (inPath(arena, io, env, c.argv[0])) {
                chosen = c;
                break;
            }
        }
        try steps.append(arena, .{
            .block = b,
            .status = if (chosen != null) .run else .no_runtime,
            .tried = tried.items,
            .launch = chosen,
        });
    }
    return steps.items;
}

pub fn plan(
    arena: Allocator,
    io: Io,
    cmd: *const Command,
    env: *const std.process.Environ.Map,
) Allocator.Error![]const Step {
    return planFor(arena, io, cmd, env, builtin.os.tag);
}

/// Runs every block of `cmd` in order; stops at the first failure
/// and returns its exit code.
pub fn runCommand(
    arena: Allocator,
    io: Io,
    cmd: *const Command,
    env: *const std.process.Environ.Map,
    verbose: bool,
) Allocator.Error!u8 {
    const steps = try plan(arena, io, cmd, env);

    var runnable: usize = 0;
    for (steps) |st| {
        switch (st.status) {
            .run => runnable += 1,
            .no_runtime => {
                std.debug.print("kevin: no runtime found in PATH for '{s}' (tried: ", .{st.block.lang});
                for (st.tried, 0..) |t, i| std.debug.print("{s}{s}", .{ if (i > 0) ", " else "", t });
                std.debug.print(")\n", .{});
                return 127;
            },
            .skipped => {},
        }
    }
    if (runnable == 0) {
        std.debug.print("kevin: command '{s}' has no runnable code block for this OS\n", .{cmd.name});
        return 1;
    }

    for (steps) |st| {
        if (st.status != .run) continue;
        const b = st.block;
        const launch = st.launch.?;

        if (verbose) {
            std.debug.print("+ [{s}] {s}:{d}\n{s}", .{ b.lang, cmd.source_path, b.line, b.code });
            if (b.code.len == 0 or b.code[b.code.len - 1] != '\n') std.debug.print("\n", .{});
        }

        var child = std.process.spawn(io, .{
            .argv = launch.argv,
            .environ_map = env,
            .stdin = if (launch.stdin != null) .pipe else .inherit,
        }) catch |err| {
            std.debug.print("kevin: failed to run '{s}': {t}\n", .{ launch.argv[0], err });
            return 126;
        };
        if (launch.stdin) |code| {
            if (child.stdin) |f| {
                f.writeStreamingAll(io, code) catch {};
                f.close(io);
                child.stdin = null;
            }
        }
        const term = child.wait(io) catch |err| {
            std.debug.print("kevin: wait failed: {t}\n", .{err});
            return 1;
        };
        const code = exitCode(term);
        if (code != 0) return code;
    }
    return 0;
}

// -------------------------------------------------------------------- tests

const testing = std.testing;

fn blk(lang: []const u8, code: []const u8) CodeBlock {
    return .{ .lang = lang, .code = code, .line = 1 };
}

test "kindOf maps languages and ignores data blocks" {
    try testing.expectEqual(Kind.bash, kindOf("BASH").?);
    try testing.expectEqual(Kind.ts, kindOf("typescript").?);
    try testing.expectEqual(Kind.py, kindOf("py").?);
    try testing.expect(kindOf("json") == null);
    try testing.expect(kindOf("yaml") == null);
    try testing.expect(kindOf("") == null);
    try testing.expect(kindOf("text") == null);
}

test "sequential blocks keep order and skip data blocks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = [_]CodeBlock{ blk("bash", "a"), blk("json", "{}"), blk("python", "b"), blk("", "x") };
    const out = try selectBlocks(arena, &input, .linux);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("a", out[0].code);
    try testing.expectEqualStrings("b", out[1].code);
}

test "multiplatform selection picks the block for the current OS" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = [_]CodeBlock{ blk("bash", "posix"), blk("powershell", "win"), blk("python", "both") };

    const linux = try selectBlocks(arena, &input, .linux);
    try testing.expectEqual(@as(usize, 2), linux.len);
    try testing.expectEqualStrings("posix", linux[0].code);
    try testing.expectEqualStrings("both", linux[1].code);

    const macos = try selectBlocks(arena, &input, .macos);
    try testing.expectEqualStrings("posix", macos[0].code);

    const win = try selectBlocks(arena, &input, .windows);
    try testing.expectEqual(@as(usize, 2), win.len);
    try testing.expectEqualStrings("win", win[0].code);

    // A lone PowerShell block is kept even on POSIX (pwsh may be installed).
    const only = [_]CodeBlock{blk("pwsh", "x")};
    try testing.expectEqual(@as(usize, 1), (try selectBlocks(arena, &only, .linux)).len);
}

test "runtime candidates and fallbacks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const py = try candidates(arena, .py, "print(1)");
    try testing.expectEqualStrings("uv", py[0].argv[0]);
    try testing.expectEqualStrings("python3", py[1].argv[0]);
    const ts = try candidates(arena, .ts, "1");
    try testing.expectEqualStrings("bun", ts[0].argv[0]);
    try testing.expectEqualStrings("1", ts[0].stdin.?);
    try testing.expectEqualStrings("tsx", ts[1].argv[0]);
}

test "plan explains skipped blocks and missing runtimes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cmd: Command = .{ .name = "demo" };
    try cmd.blocks.append(arena, blk("json", "{}"));
    try cmd.blocks.append(arena, blk("bash", "echo posix"));
    try cmd.blocks.append(arena, blk("powershell", "Write-Host win"));
    try cmd.blocks.append(arena, blk("", "plain"));

    var env = std.process.Environ.Map.init(arena); // empty PATH: no runtime can be found
    const steps = try planFor(arena, testing.io, &cmd, &env, .linux);
    try testing.expectEqual(@as(usize, 4), steps.len);
    try testing.expectEqual(Status.skipped, steps[0].status);
    try testing.expect(std.mem.indexOf(u8, steps[0].reason, "'json'") != null);
    try testing.expectEqual(Status.no_runtime, steps[1].status);
    try testing.expectEqualStrings("bash", steps[1].tried[0]);
    try testing.expectEqual(Status.skipped, steps[2].status);
    try testing.expect(std.mem.indexOf(u8, steps[2].reason, "linux") != null);
    try testing.expectEqualStrings("no language", steps[3].reason);

    try env.put("PATH", "/bin:/usr/bin");
    const with_path = try planFor(arena, testing.io, &cmd, &env, .linux);
    if (builtin.os.tag != .windows) {
        try testing.expectEqual(Status.run, with_path[1].status);
        try testing.expectEqualStrings("-c", with_path[1].launch.?.argv[1]);
    }
}
