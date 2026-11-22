const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const cli = @import("cli.zig");
const runner = @import("runner.zig");

test {
    _ = ast;
    _ = parser;
    _ = cli;
    _ = runner;
}

const default_files = [_][]const u8{ "readme.md", "tasks.md", "build.md" };
const max_file_size = 16 * 1024 * 1024;

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

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    // One arena owns the whole AST and every file buffer.
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try init.minimal.args.toSlice(arena);

    // Global flags are only recognised before the command name.
    var file_arg: ?[]const u8 = null;
    var tokens: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a: []const u8 = argv[i];
        if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--file")) {
            i += 1;
            if (i >= argv.len) return fail("{s} requires a path", .{a});
            file_arg = argv[i];
        } else if (std.mem.startsWith(u8, a, "--file=")) {
            file_arg = a["--file=".len..];
        } else if (a.len > 0 and a[0] == '-') {
            try tokens.append(arena, a);
        } else {
            try tokens.appendSlice(arena, @ptrCast(argv[i..]));
            break;
        }
    }

    var names: []const []const u8 = undefined;
    if (file_arg) |f| {
        names = try arena.dupe([]const u8, &.{f});
    } else {
        names = try discover(arena, io);
    }

    const root = try arena.create(ast.Command);
    root.* = .{ .name = "" };
    var warnings: std.ArrayList([]const u8) = .empty;
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
    for (warnings.items) |w| std.debug.print("kevin: warning: {s}\n", .{w});

    var out_buf: [4096]u8 = undefined;
    var out_file = Io.File.stdout().writer(io, &out_buf);
    const out = &out_file.interface;

    if (names.len == 0 and tokens.items.len == 0) {
        return fail("no README.md, tasks.md or build.md found (use --file <path>)", .{});
    }

    const resolved = try cli.resolve(arena, root, tokens.items);
    var msg: []const u8 = "";

    // A namespace (no code of its own) followed by a stray word is a typo, not an argument.
    if (resolved.cmd.blocks.items.len == 0 and resolved.cmd.children.items.len > 0) {
        for (resolved.rest) |t| {
            if (t.len > 0 and t[0] != '-') {
                std.debug.print("kevin: unknown command '{s}'\n", .{t});
                return 2;
            }
        }
    }
    const inv = cli.parseInvocation(arena, resolved.cmd, resolved.rest, &msg) catch |err| switch (err) {
        error.Usage => {
            std.debug.print("kevin: {s}\n", .{msg});
            if (resolved.cmd != root and resolved.cmd.blocks.items.len == 0 and resolved.cmd.children.items.len > 0) {
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
    const no_code = resolved.cmd.blocks.items.len == 0;
    // A namespace (or the root) with nothing runnable prints help; a bad name is an error.
    if (inv.help or is_root or no_code) {
        if (is_root) {
            try cli.printRootHelp(arena, out, root, sources.items);
        } else {
            try cli.printCommandHelp(arena, out, resolved.cmd, resolved.path);
        }
        try out.flush();
        return if (inv.help or children(resolved.cmd)) 0 else 1;
    }

    // Child environment: inherited + args/flags + utilities.
    var env = try init.environ_map.clone(arena);
    for (inv.env) |p| try env.put(p.name, p.value);
    const exe = try std.process.executablePathAlloc(io, arena);
    const md_path = resolved.cmd.source_path;
    try env.put("KEVIN", try std.fmt.allocPrint(arena, "{s} --file {s}", .{ exe, md_path }));
    try env.put("KEVIN_DIR", std.fs.path.dirname(md_path) orelse ".");
    if (inv.verbose) {
        try env.put("verbose", "true");
        try env.put("KEVIN_VERBOSE", "true");
    }

    return runner.runCommand(arena, io, resolved.cmd, &env, inv.verbose);
}

fn children(cmd: *const ast.Command) bool {
    return cmd.children.items.len > 0 or cmd.name.len == 0;
}
