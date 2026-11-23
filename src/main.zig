const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const cli = @import("cli.zig");
const runner = @import("runner.zig");
const migrate = @import("migrate.zig");
const explain = @import("explain.zig");
const deps = @import("deps.zig");
const proc = @import("proc.zig");
const introspect = @import("introspect.zig");
const complete = @import("complete.zig");
const update = @import("update.zig");
const kevinrc = @import("kevinrc.zig");
const build_options = @import("build_options");

test {
    _ = ast;
    _ = parser;
    _ = cli;
    _ = runner;
    _ = migrate;
    _ = explain;
    _ = deps;
    _ = proc;
    _ = introspect;
    _ = complete;
    _ = update;
    _ = kevinrc;
}

const default_files = [_][]const u8{ "readme.md", "tasks.md", "build.md" };
const max_file_size = 16 * 1024 * 1024;
/// Upper bound of async worker threads (waiting tasks are cheap, but not free).
const max_threads = 1024;

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("kevin: " ++ fmt ++ "\n", args);
    return 2;
}

/// Case-insensitive lookup of README.md / tasks.md / build.md in the cwd.
fn discover(arena: std.mem.Allocator, io: Io) ![]const []const u8 {
    var dir = try Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var found: [default_files.len]?[]const u8 = @splat(null);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        for (default_files, 0..) |want, i| {
            if (found[i] == null and std.ascii.eqlIgnoreCase(entry.name, want)) {
                found[i] = try arena.dupe(u8, entry.name);
            }
        }
    }
    var out: std.ArrayList([]const u8) = .empty;
    for (found) |f| if (f) |name| try out.append(arena, name);
    return out.items;
}

/// Disk access for `kevinrc.resolve`, relative to the current directory.
const DiskFs = struct {
    io: Io,

    /// Names of the files (and symlinks) in `dir`; a missing directory is empty.
    pub fn list(self: DiskFs, arena: std.mem.Allocator, dir: []const u8) ![]const []const u8 {
        var d = Io.Dir.cwd().openDir(self.io, if (dir.len == 0) "." else dir, .{ .iterate = true }) catch return &.{};
        defer d.close(self.io);
        var out: std.ArrayList([]const u8) = .empty;
        var it = d.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            try out.append(arena, try arena.dupe(u8, entry.name));
        }
        return out.items;
    }

    /// Real absolute path of a regular file (or a symlink to one).
    pub fn real(self: DiskFs, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
        const st = Io.Dir.cwd().statFile(self.io, path, .{}) catch return null;
        if (st.kind != .file) return null;
        const abs = Io.Dir.cwd().realPathFileAlloc(self.io, path, arena) catch return null;
        return abs;
    }
};

/// The files kevin reads when no `-f` is given: the defaults, adjusted by
/// `.kevinrc` in the current directory (never in a parent).
const Discovered = struct {
    names: []const []const u8,
    reasons: []const []const u8,
    excluded: []const []const u8,
    warnings: []const []const u8,
};

fn discoverFiles(arena: std.mem.Allocator, io: Io) !Discovered {
    const defaults = try discover(arena, io);
    const text = Io.Dir.cwd().readFileAlloc(io, kevinrc.file_name, arena, .limited(max_file_size)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    var names: std.ArrayList([]const u8) = .empty;
    var reasons: std.ArrayList([]const u8) = .empty;
    var excluded: std.ArrayList([]const u8) = .empty;
    var warnings: std.ArrayList([]const u8) = .empty;
    if (text == null) {
        for (defaults) |d| {
            try names.append(arena, d);
            try reasons.append(arena, "default");
        }
        return .{ .names = names.items, .reasons = reasons.items, .excluded = &.{}, .warnings = &.{} };
    }
    const parsed = try kevinrc.parse(arena, text.?);
    try warnings.appendSlice(arena, parsed.warnings);
    const res = try kevinrc.resolve(arena, parsed.rules, defaults, DiskFs{ .io = io });
    try warnings.appendSlice(arena, res.warnings);
    for (res.files) |f| {
        try names.append(arena, f.path);
        try reasons.append(arena, switch (f.origin) {
            .default => "default",
            .include => |line| try std.fmt.allocPrint(arena, ".kevinrc line {d}", .{line}),
        });
    }
    for (res.excluded) |e| try excluded.append(arena, try std.fmt.allocPrint(arena, "{s} (.kevinrc line {d})", .{ e.path, e.line }));
    return .{ .names = names.items, .reasons = reasons.items, .excluded = excluded.items, .warnings = warnings.items };
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    // One arena owns the whole AST and every file buffer.
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try init.minimal.args.toSlice(arena);

    // Global flags are only recognised before the command name.
    var file_args: std.ArrayList([]const u8) = .empty;
    var from_arg: ?[]const u8 = null;
    var output_arg: ?[]const u8 = null;
    var explain_flag = false;
    var introspect_flag = false;
    var jobs_arg: ?[]const u8 = null;
    // Hidden: `--complete <words...>` feeds the shell completion scripts.
    var complete_words: ?[]const []const u8 = null;
    var tokens: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a: []const u8 = argv[i];
        if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--file")) {
            i += 1;
            if (i >= argv.len) return fail("{s} requires a path", .{a});
            try file_args.append(arena, argv[i]);
        } else if (std.mem.startsWith(u8, a, "--file=")) {
            try file_args.append(arena, a["--file=".len..]);
        } else if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V")) {
            var buf: [64]u8 = undefined;
            var w = Io.File.stdout().writer(io, &buf);
            try w.interface.print("kevin {s}\n", .{build_options.version});
            try w.interface.flush();
            return 0;
        } else if (std.mem.eql(u8, a, "--check-update")) {
            return checkUpdate(init.gpa, io);
        } else if (std.mem.eql(u8, a, "--completion")) {
            i += 1;
            const shell = if (i < argv.len) std.meta.stringToEnum(complete.Shell, argv[i]) else null;
            if (shell == null) return fail("--completion requires 'zsh', 'bash' or 'fish'", .{});
            var buf: [4096]u8 = undefined;
            var w = Io.File.stdout().writer(io, &buf);
            try w.interface.writeAll(complete.script(shell.?));
            try w.interface.flush();
            return 0;
        } else if (std.mem.eql(u8, a, "--complete")) {
            complete_words = @ptrCast(argv[i + 1 ..]);
            break;
        } else if (std.mem.eql(u8, a, "-j") or std.mem.eql(u8, a, "--jobs")) {
            i += 1;
            if (i >= argv.len) return fail("{s} requires a number", .{a});
            jobs_arg = argv[i];
        } else if (std.mem.startsWith(u8, a, "--jobs=")) {
            jobs_arg = a["--jobs=".len..];
        } else if (std.mem.eql(u8, a, "--introspect")) {
            introspect_flag = true;
        } else if (std.mem.eql(u8, a, "--explain")) {
            explain_flag = true;
        } else if (std.mem.eql(u8, a, "--from")) {
            i += 1;
            if (i >= argv.len) return fail("--from requires 'mask' or 'xc'", .{});
            from_arg = argv[i];
        } else if (std.mem.startsWith(u8, a, "--from=")) {
            from_arg = a["--from=".len..];
        } else if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--output")) {
            i += 1;
            if (i >= argv.len) return fail("{s} requires a path", .{a});
            output_arg = argv[i];
        } else if (std.mem.startsWith(u8, a, "--output=")) {
            output_arg = a["--output=".len..];
        } else if (a.len > 0 and a[0] == '-') {
            try tokens.append(arena, a);
        } else {
            try tokens.appendSlice(arena, @ptrCast(argv[i..]));
            break;
        }
    }

    if (from_arg) |from| {
        if (tokens.items.len > 0) return fail("--from does not take a command (got '{s}')", .{tokens.items[0]});
        return runMigration(arena, io, from, if (file_args.items.len > 0) file_args.items[file_args.items.len - 1] else null, output_arg);
    }
    if (output_arg != null) return fail("--output is only valid together with --from", .{});

    var names: []const []const u8 = undefined;
    var reasons: []const []const u8 = &.{};
    var excluded_files: []const []const u8 = &.{};
    var warnings: std.ArrayList([]const u8) = .empty;
    if (file_args.items.len > 0) {
        // -f means exactly these files; .kevinrc is ignored.
        names = file_args.items;
        const rs = try arena.alloc([]const u8, names.len);
        @memset(rs, "--file");
        reasons = rs;
    } else {
        const d = discoverFiles(arena, io) catch |err|
            return fail("cannot read '{s}': {t}", .{ kevinrc.file_name, err });
        names = d.names;
        reasons = d.reasons;
        excluded_files = d.excluded;
        try warnings.appendSlice(arena, d.warnings);
    }

    const root = try arena.create(ast.Command);
    root.* = .{ .name = "" };
    var sources: std.ArrayList([]const u8) = .empty;

    for (names) |name| {
        const abs = Io.Dir.cwd().realPathFileAlloc(io, name, arena) catch |err|
            return fail("cannot open '{s}': {t}", .{ name, err });
        const src = Io.Dir.cwd().readFileAlloc(io, abs, arena, .limited(max_file_size)) catch |err|
            return fail("cannot read '{s}': {t}", .{ name, err });
        const parsed = try parser.parseSource(arena, abs, src);
        try warnings.appendSlice(arena, parsed.warnings.items);
        try ast.merge(arena, root, parsed.root, &warnings);
        try sources.append(arena, abs);
    }
    if (complete_words == null) {
        for (warnings.items) |w| std.debug.print("kevin: warning: {s}\n", .{w});
    }

    var out_buf: [4096]u8 = undefined;
    var out_file = Io.File.stdout().writer(io, &out_buf);
    const out = &out_file.interface;

    if (complete_words) |words| {
        try complete.candidates(arena, out, root, words);
        try out.flush();
        return 0;
    }

    if (names.len == 0) {
        var only_help = tokens.items.len > 0;
        for (tokens.items) |t| {
            if (!std.mem.eql(u8, t, "-h") and !std.mem.eql(u8, t, "--help")) only_help = false;
        }
        if (only_help) {
            try cli.printRootHelp(arena, out, root, sources.items);
            try out.flush();
            return 0;
        }
        return fail("no README.md, tasks.md or build.md found in the current directory (use --file <path>)", .{});
    }

    if (introspect_flag) {
        try introspect.write(arena, out, root, sources.items, build_options.version);
        try out.flush();
        return 0;
    }

    const resolved = try cli.resolve(arena, root, tokens.items);
    var msg: []const u8 = "";

    // A namespace (no code of its own) followed by a stray word is a typo, not an argument.
    if (!resolved.cmd.hasWork() and resolved.cmd.children.items.len > 0) {
        for (resolved.rest) |t| {
            if (t.len > 0 and t[0] != '-') {
                std.debug.print("kevin: unknown command '{s}'\n", .{t});
                return 2;
            }
        }
    }
    var usage_error: ?[]const u8 = null;
    const inv = cli.parseInvocation(arena, resolved.cmd, resolved.rest, &msg) catch |err| switch (err) {
        error.Usage => blk: {
            usage_error = msg;
            if (explain_flag) break :blk cli.Invocation{};
            std.debug.print("kevin: {s}\n", .{msg});
            if (resolved.cmd != root and !resolved.cmd.hasWork() and resolved.cmd.children.items.len > 0) {
                std.debug.print("Run 'kevin {s} --help' to list subcommands.\n", .{try std.mem.join(arena, " ", resolved.path)});
            } else {
                std.debug.print("Run 'kevin {s}{s}--help' for usage.\n", .{
                    try std.mem.join(arena, " ", resolved.path),
                    if (resolved.path.len > 0) " " else "",
                });
            }
            return 2;
        },
        else => |e| return e,
    };

    const is_root = resolved.cmd == root;
    const no_code = !resolved.cmd.hasWork();
    // A namespace (or the root) with nothing runnable prints help; a bad name is an error.
    if (!explain_flag and (inv.help or is_root or no_code)) {
        if (is_root) {
            try cli.printRootHelp(arena, out, root, sources.items);
        } else {
            try cli.printCommandHelp(arena, out, resolved.cmd, resolved.path);
        }
        try out.flush();
        return if (inv.help or children(resolved.cmd)) 0 else 1;
    }

    // Maximum number of scripts running at once: --jobs, then $KEVIN_JOBS, then the CPU count.
    const jobs_text: ?[]const u8 = jobs_arg orelse init.environ_map.get("KEVIN_JOBS");
    var jobs: usize = std.Thread.getCpuCount() catch 4;
    if (jobs_text) |t| {
        jobs = std.fmt.parseInt(usize, t, 10) catch 0;
        if (jobs == 0) return fail("invalid number of jobs '{s}' (expected a positive integer)", .{t});
    }

    // Resolve the whole dependency tree up front: unknown tasks, bad arguments
    // and cycles fail before anything runs.
    var builder: deps.Builder = .{ .arena = arena, .root = root };
    var graph: ?*deps.Node = null;
    var dep_error: ?[]const u8 = null;
    if (usage_error == null and !inv.help) {
        if (builder.build(resolved.cmd, inv.env)) |n| {
            graph = n;
        } else |err| switch (err) {
            error.Invalid => dep_error = builder.err,
            error.OutOfMemory => return err,
        }
    }

    if (init.environ_map.get("KEVIN_DEPTH")) |d| deps.depth = std.fmt.parseInt(u32, d, 10) catch 0;

    const exe = try std.process.executablePathAlloc(io, arena);
    const injected = try deps.injectedVars(arena, exe, sources.items, resolved.cmd, inv.env, inv.verbose, jobs);

    if (explain_flag) {
        const steps: []const runner.Step = if (graph != null and !is_root and !no_code) blk: {
            var env = try init.environ_map.clone(arena);
            for (injected) |p| try env.put(p.name, p.value);
            for (inv.unset) |n| _ = env.swapRemove(n);
            break :blk try runner.plan(arena, io, resolved.cmd, &env);
        } else &.{};
        try explain.print(out, .{
            .sources = sources.items,
            .reasons = reasons,
            .excluded = excluded_files,
            .warnings = warnings.items,
            .cmd = resolved.cmd,
            .path = resolved.path,
            .invocation = inv,
            .usage_error = usage_error orelse dep_error,
            .injected = injected,
            .steps = steps,
            .graph = graph,
            .jobs = jobs,
        });
        try out.flush();
        if (usage_error != null or dep_error != null) return 2;
        for (steps) |st| if (st.status == .no_runtime) return 127;
        return 0;
    }

    if (dep_error) |msg_text| {
        std.debug.print("kevin: {s}\n", .{msg_text});
        return 2;
    }

    if (deps.depth >= deps.max_depth) {
        return fail("tasks are nested {d} kevin runs deep (KEVIN_DEPTH); a task probably calls itself through $KEVIN", .{deps.depth});
    }

    // The async runtime must be able to hold one thread per task that may wait
    // at the same time; the number of scripts running at once is bounded by
    // the --jobs semaphore, not by the thread pool.
    const node_count = try deps.countNodes(arena, graph.?);
    var threaded: Io.Threaded = .init(init.gpa, .{
        .async_limit = .limited(@min(node_count, max_threads)),
        .environ = init.minimal.environ,
    });
    defer threaded.deinit();
    const exec_io = threaded.io();

    // Children get their own process group unless stdin is a terminal (a
    // background group cannot read it).
    const interactive = Io.File.stdin().isTty(io) catch false;
    proc.installSignalHandlers(!interactive);
    defer proc.cleanupTemp(exec_io);

    var ctx: deps.Ctx = .{
        .arena = arena,
        .io = exec_io,
        .base_env = init.environ_map,
        .exe = exe,
        .files = sources.items,
        .verbose = inv.verbose,
        .jobs = jobs,
        .slots = .{ .permits = jobs },
    };
    const code = deps.execute(&ctx, graph.?);
    return proc.signalExitCode() orelse code;
}

fn checkUpdate(gpa: std.mem.Allocator, io: Io) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const res = try update.check(arena_state.allocator(), io, build_options.version);
    switch (res) {
        .up_to_date => |tag| std.debug.print("kevin {s} is up to date (latest release: {s})\n", .{ build_options.version, tag }),
        .available => |tag| std.debug.print(
            "kevin {s} is available (you have {s}).\nUpdate: curl -fsSL https://raw.githubusercontent.com/mtxr/kevin/main/install.sh | sh\nOr see {s}\n",
            .{ tag, build_options.version, update.releases_url },
        ),
        .failed => |why| {
            std.debug.print("kevin: update check failed: {s}\n", .{why});
            return 1;
        },
    }
    return 0;
}

fn children(cmd: *const ast.Command) bool {
    return cmd.children.items.len > 0 or cmd.name.len == 0;
}

/// `kevin --from mask|xc [-f input.md] [-o output.md]`: converts a foreign
/// file to kevin syntax. Writes to stdout unless `-o` is given; never
/// overwrites an existing file.
fn runMigration(
    arena: std.mem.Allocator,
    io: Io,
    from: []const u8,
    file_arg: ?[]const u8,
    output_arg: ?[]const u8,
) !u8 {
    const source = migrate.Source.parse(from) orelse
        return fail("unknown source '{s}' for --from (expected 'mask' or 'xc')", .{from});
    const path = file_arg orelse source.defaultFile();
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_size)) catch |err|
        return fail("cannot read '{s}': {t}", .{ path, err });

    const result = migrate.migrate(arena, source, text) catch |err| switch (err) {
        error.NoTasksSection => return fail("'{s}' has no 'Tasks' heading (xc needs one; see https://xcfile.dev)", .{path}),
        error.OutOfMemory => return err,
    };

    if (output_arg) |out_path| {
        var file = Io.Dir.cwd().createFile(io, out_path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => return fail("'{s}' already exists; refusing to overwrite it", .{out_path}),
            else => return fail("cannot create '{s}': {t}", .{ out_path, err }),
        };
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.writeAll(result.output);
        try w.interface.flush();
    } else {
        var buf: [4096]u8 = undefined;
        var w = Io.File.stdout().writer(io, &buf);
        try w.interface.writeAll(result.output);
        try w.interface.flush();
    }
    for (result.notes) |n| std.debug.print("kevin: note: {s}\n", .{n});
    return 0;
}
