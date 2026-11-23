//! Block selection (OS filtering), runtime mapping and process execution.

const std = @import("std");
const builtin = @import("builtin");
const ast = @import("ast.zig");
const proc = @import("proc.zig");
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

/// How to run one block: the interpreter (plus flags), the file the code is
/// written to and the arguments that follow the file. The final command line
/// is `argv... <script file> args...`; the file lives in kevin's private temp
/// directory, so stdin stays untouched and the code size is not limited by argv.
pub const Launch = struct {
    /// Interpreter and its flags; the script path is appended after them.
    argv: []const []const u8,
    /// Script file extension, with the dot (interpreters often key off it).
    ext: []const u8,
    /// What is written to the script file.
    code: []const u8,
    /// Arguments after the script path (`$1..$n` of shell blocks).
    args: []const []const u8 = &.{},
};

/// Ordered runtime candidates; the first one found in PATH is used.
pub fn candidates(arena: Allocator, kind: Kind, code: []const u8) Allocator.Error![]const Launch {
    const L = struct {
        fn mk(al: Allocator, parts: []const []const u8, ext: []const u8, src: []const u8) Allocator.Error!Launch {
            return .{ .argv = try al.dupe([]const u8, parts), .ext = ext, .code = src };
        }
    };
    var out: std.ArrayList(Launch) = .empty;
    switch (kind) {
        .sh => try out.append(arena, try L.mk(arena, &.{"sh"}, ".sh", code)),
        .bash => try out.append(arena, try L.mk(arena, &.{"bash"}, ".sh", code)),
        .zsh => try out.append(arena, try L.mk(arena, &.{"zsh"}, ".zsh", code)),
        .fish => try out.append(arena, try L.mk(arena, &.{"fish"}, ".fish", code)),
        .js => {
            try out.append(arena, try L.mk(arena, &.{"node"}, ".js", code));
            try out.append(arena, try L.mk(arena, &.{ "bun", "run" }, ".js", code));
        },
        .ts => {
            try out.append(arena, try L.mk(arena, &.{ "bun", "run" }, ".ts", code));
            try out.append(arena, try L.mk(arena, &.{"tsx"}, ".ts", code));
            try out.append(arena, try L.mk(arena, &.{ "deno", "run", "-A" }, ".ts", code));
        },
        .py => {
            try out.append(arena, try L.mk(arena, &.{"python3"}, ".py", code));
            try out.append(arena, try L.mk(arena, &.{"python"}, ".py", code));
            // --no-project: never create .venv or uv.lock in the user's project.
            try out.append(arena, try L.mk(arena, &.{ "uv", "run", "--no-project", "python" }, ".py", code));
        },
        .ruby => try out.append(arena, try L.mk(arena, &.{"ruby"}, ".rb", code)),
        .lua => try out.append(arena, try L.mk(arena, &.{"lua"}, ".lua", code)),
        .php => try out.append(arena, try L.mk(arena, &.{"php"}, ".php", try phpSource(arena, code))),
        .pwsh => {
            try out.append(arena, try L.mk(arena, &.{ "pwsh", "-NoProfile", "-File" }, ".ps1", code));
            try out.append(arena, try L.mk(arena, &.{ "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" }, ".ps1", code));
        },
        .bat => try out.append(arena, try L.mk(arena, &.{ "cmd", "/c" }, ".bat", try batSource(arena, code))),
    }
    return out.items;
}

/// PHP files are HTML until an open tag: add one unless the block has its own.
fn phpSource(arena: Allocator, code: []const u8) Allocator.Error![]const u8 {
    if (std.mem.startsWith(u8, std.mem.trimStart(u8, code, " \t\r\n"), "<?")) return code;
    return std.fmt.allocPrint(arena, "<?php\n{s}", .{code});
}

/// Batch files: no command echo (like `cmd /c <command>`) and CRLF line endings.
fn batSource(arena: Allocator, code: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "@echo off\r\n");
    var it = std.mem.splitScalar(u8, code, '\n');
    while (it.next()) |line| {
        const l = std.mem.trimEnd(u8, line, "\r");
        if (it.peek() == null and l.len == 0) break; // trailing newline
        try out.appendSlice(arena, l);
        try out.appendSlice(arena, "\r\n");
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
            .launch = if (chosen) |c| try withPositional(arena, c, cmd, env) else null,
        });
    }
    return steps.items;
}

fn envValue(env: *const std.process.Environ.Map, name: []const u8) []const u8 {
    return env.get(name) orelse "";
}

/// Shell blocks also receive the declared arguments as `$1..$n` (and `$@`), the
/// way xc passes them, on top of the named variables. Trailing optional
/// arguments that were not given are left out, so `$#` is meaningful. `$0` is
/// the script file.
fn withPositional(arena: Allocator, launch: Launch, cmd: *const Command, env: *const std.process.Environ.Map) Allocator.Error!Launch {
    const shell = launch.argv.len == 1 and launch.args.len == 0 and
        (std.mem.eql(u8, launch.argv[0], "sh") or std.mem.eql(u8, launch.argv[0], "bash") or std.mem.eql(u8, launch.argv[0], "zsh"));
    if (!shell or cmd.args.items.len == 0) return launch;

    var n = cmd.args.items.len;
    while (n > 0) : (n -= 1) {
        const a = cmd.args.items[n - 1];
        if (a.required or envValue(env, a.name).len > 0) break;
    }
    if (n == 0) return launch;

    const args = try arena.alloc([]const u8, n);
    for (cmd.args.items[0..n], args) |a, *slot| slot.* = envValue(env, a.name);
    var l = launch;
    l.args = args;
    return l;
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
        if (proc.shouldStop()) return proc.stopped_code;
        const b = st.block;
        const launch = st.launch.?;

        if (verbose) {
            std.debug.print("+ [{s}] {s}:{d}\n{s}", .{ b.lang, cmd.source_path, b.line, b.code });
            if (b.code.len == 0 or b.code[b.code.len - 1] != '\n') std.debug.print("\n", .{});
        }

        const code = runBlock(arena, io, cmd, env, launch);
        if (code != 0) return code;
    }
    return 0;
}

/// Writes the block to a temp file, runs the interpreter on it with stdin
/// inherited, and always removes the file again.
fn runBlock(
    arena: Allocator,
    io: Io,
    cmd: *const Command,
    env: *const std.process.Environ.Map,
    launch: Launch,
) u8 {
    const path = proc.writeScript(arena, io, env, cmd.name, launch.ext, launch.code) catch return 126;
    defer proc.removeScript(io, path);

    const argv = arena.alloc([]const u8, launch.argv.len + 1 + launch.args.len) catch return 1;
    @memcpy(argv[0..launch.argv.len], launch.argv);
    argv[launch.argv.len] = path;
    @memcpy(argv[launch.argv.len + 1 ..], launch.args);

    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = env,
        .stdin = .inherit,
        .pgid = if (comptime builtin.os.tag == .windows) null else if (proc.ownGroups()) @as(?std.posix.pid_t, 0) else null,
    }) catch |err| {
        std.debug.print("kevin: failed to run '{s}': {t}\n", .{ launch.argv[0], err });
        return 126;
    };
    const tracked = proc.track(childId(&child));
    defer proc.untrack(tracked);

    const term = child.wait(io) catch |err| {
        std.debug.print("kevin: wait failed: {t}\n", .{err});
        return 1;
    };
    return exitCode(term);
}

fn childId(child: *const std.process.Child) usize {
    const id = child.id orelse return 0;
    return if (builtin.os.tag == .windows) @intFromPtr(id) else @intCast(id);
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
    try testing.expectEqualStrings("python3", py[0].argv[0]);
    try testing.expectEqualStrings("python", py[1].argv[0]);
    // uv is the last resort and never touches the project.
    try testing.expectEqualStrings("uv", py[2].argv[0]);
    try testing.expectEqualStrings("--no-project", py[2].argv[2]);
    try testing.expectEqualStrings(".py", py[0].ext);
    try testing.expectEqualStrings("print(1)", py[0].code);

    const ts = try candidates(arena, .ts, "1");
    try testing.expectEqualStrings("bun", ts[0].argv[0]);
    try testing.expectEqualStrings("run", ts[0].argv[1]);
    try testing.expectEqualStrings("tsx", ts[1].argv[0]);
    try testing.expectEqualStrings("deno", ts[2].argv[0]);
    try testing.expectEqualStrings("-A", ts[2].argv[2]);
    for (ts) |l| try testing.expectEqualStrings(".ts", l.ext);
}

test "every launcher runs a file, never argv code" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (std.enums.values(Kind)) |kind| {
        for (try candidates(arena, kind, "SECRET_CODE")) |l| {
            for (l.argv) |a| try testing.expect(std.mem.indexOf(u8, a, "SECRET_CODE") == null);
            try testing.expect(l.ext.len > 1 and l.ext[0] == '.');
            try testing.expect(std.mem.indexOf(u8, l.code, "SECRET_CODE") != null);
        }
    }
    const sh = try candidates(arena, .bash, "echo $1");
    try testing.expectEqual(@as(usize, 1), sh[0].argv.len);
    try testing.expectEqualStrings("bash", sh[0].argv[0]);
    const ps = try candidates(arena, .pwsh, "x");
    try testing.expectEqualStrings("-File", ps[0].argv[ps[0].argv.len - 1]);
    try testing.expectEqualStrings("Bypass", ps[1].argv[3]);
}

test "php code gets an open tag unless it has one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("<?php\necho 1;", (try candidates(arena, .php, "echo 1;"))[0].code);
    try testing.expectEqualStrings("<?php echo 1;", (try candidates(arena, .php, "<?php echo 1;"))[0].code);
    try testing.expectEqualStrings("\n<?= 1 ?>", (try candidates(arena, .php, "\n<?= 1 ?>"))[0].code);
}

test "batch files are quiet and use CRLF" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const l = (try candidates(arena, .bat, "echo a\necho b\n"))[0];
    try testing.expectEqualStrings("@echo off\r\necho a\r\necho b\r\n", l.code);
    try testing.expectEqualStrings("cmd", l.argv[0]);
}

test "shell blocks receive declared arguments as positional parameters" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cmd: Command = .{ .name = "greet" };
    try cmd.args.append(arena, .{ .name = "first", .required = true });
    try cmd.args.append(arena, .{ .name = "second", .required = false });
    var env = std.process.Environ.Map.init(arena);
    try env.put("first", "a");
    try env.put("second", "");
    const base: Launch = .{ .argv = &.{"bash"}, .ext = ".sh", .code = "echo $1" };
    const l = try withPositional(arena, base, &cmd, &env);
    try testing.expectEqual(@as(usize, 1), l.args.len); // bash <file> a
    try testing.expectEqualStrings("a", l.args[0]);

    try env.put("second", "b");
    const l2 = try withPositional(arena, .{ .argv = &.{"sh"}, .ext = ".sh", .code = "x" }, &cmd, &env);
    try testing.expectEqual(@as(usize, 2), l2.args.len);
    try testing.expectEqualStrings("b", l2.args[1]);

    // Only POSIX shells get positional parameters.
    const py = try withPositional(arena, .{ .argv = &.{"python3"}, .ext = ".py", .code = "x" }, &cmd, &env);
    try testing.expectEqual(@as(usize, 0), py.args.len);
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

    // A POSIX PATH is not a valid Windows path (the OS rejects the names).
    if (builtin.os.tag != .windows) {
        try env.put("PATH", "/bin:/usr/bin");
        const with_path = try planFor(arena, testing.io, &cmd, &env, .linux);
        try testing.expectEqual(Status.run, with_path[1].status);
        try testing.expectEqualStrings("bash", with_path[1].launch.?.argv[0]);
        try testing.expectEqualStrings(".sh", with_path[1].launch.?.ext);
    }
}

test "blocks run from a temp file with inherited stdin and exact exit codes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    defer proc.cleanupTemp(testing.io);

    var env = std.process.Environ.Map.init(arena);
    try env.put("PATH", "/bin:/usr/bin");
    try env.put("TMPDIR", "/tmp");

    var cmd: Command = .{ .name = "demo" };
    // Bigger than Linux MAX_ARG_STRLEN (128 KiB): impossible through `sh -c`.
    const filler: [200_000]u8 = @splat('x');
    const big = try std.fmt.allocPrint(arena, "# {s}\nexit 7\n", .{&filler});
    try cmd.blocks.append(arena, blk("sh", big));
    try testing.expectEqual(@as(u8, 7), try runCommand(arena, testing.io, &cmd, &env, false));

    // $1 still works, and $0 is the script file.
    var cmd2: Command = .{ .name = "demo" };
    try cmd2.args.append(arena, .{ .name = "who", .required = true });
    try env.put("who", "world");
    try cmd2.blocks.append(arena, blk("sh", "[ \"$1\" = world ] && case \"$0\" in */kevin-*) exit 3;; esac\nexit 1\n"));
    try testing.expectEqual(@as(u8, 3), try runCommand(arena, testing.io, &cmd2, &env, false));
}
