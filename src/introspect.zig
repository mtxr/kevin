//! `kevin --introspect`: the merged command tree as JSON, for editors, scripts
//! and coding agents that need to discover what a project can run.

const std = @import("std");
const ast = @import("ast.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Command = ast.Command;

const ArgJson = struct { name: []const u8, required: bool };

const FlagJson = struct {
    name: []const u8,
    short: ?[]const u8,
    long: ?[]const u8,
    type: []const u8,
    description: []const u8,
    choices: []const []const u8,
    required: bool,
};

const BlockJson = struct { lang: []const u8, line: usize, code: []const u8, example: bool };

const CommandJson = struct {
    name: []const u8,
    /// Full path from the root, e.g. ["setup", "server"].
    path: []const []const u8,
    description: []const u8,
    source: []const u8,
    line: usize,
    args: []const ArgJson,
    flags: []const FlagJson,
    requires: []const []const u8,
    run_deps: []const u8,
    run_once: bool,
    jobs: ?u32,
    blocks: []const BlockJson,
    subcommands: []const CommandJson,
};

const Document = struct {
    kevin: []const u8,
    sources: []const []const u8,
    commands: []const CommandJson,
};

fn convert(arena: Allocator, cmd: *const Command, parent_path: []const []const u8) Allocator.Error!CommandJson {
    const path = try std.mem.concat(arena, []const u8, &.{ parent_path, &.{cmd.name} });

    const args = try arena.alloc(ArgJson, cmd.args.items.len);
    for (cmd.args.items, args) |a, *o| o.* = .{ .name = a.name, .required = a.required };

    const flags = try arena.alloc(FlagJson, cmd.flags.items.len);
    for (cmd.flags.items, flags) |f, *o| o.* = .{
        .name = f.name,
        .short = f.short,
        .long = f.long,
        .type = @tagName(f.ftype),
        .description = f.desc,
        .choices = f.choices,
        .required = f.required,
    };

    const blocks = try arena.alloc(BlockJson, cmd.blocks.items.len);
    for (cmd.blocks.items, blocks) |b, *o| o.* = .{ .lang = b.lang, .line = b.line, .code = b.code, .example = b.example };

    const subs = try arena.alloc(CommandJson, cmd.children.items.len);
    for (cmd.children.items, subs) |c, *o| o.* = try convert(arena, c, path);

    return .{
        .name = cmd.name,
        .path = path,
        .description = cmd.description,
        .source = cmd.source_path,
        .line = cmd.decl_line,
        .args = args,
        .flags = flags,
        .requires = cmd.deps.requires.items,
        .run_deps = if (cmd.deps.run_deps == .async) "async" else "sync",
        .run_once = cmd.deps.run_once,
        .jobs = cmd.deps.jobs,
        .blocks = blocks,
        .subcommands = subs,
    };
}

pub fn write(
    arena: Allocator,
    w: *Io.Writer,
    root: *const Command,
    sources: []const []const u8,
    version: []const u8,
) (Allocator.Error || Io.Writer.Error)!void {
    const cmds = try arena.alloc(CommandJson, root.children.items.len);
    for (root.children.items, cmds) |c, *o| o.* = try convert(arena, c, &.{});
    const doc: Document = .{ .kevin = version, .sources = sources, .commands = cmds };
    try std.json.Stringify.value(doc, .{ .whitespace = .indent_2 }, w);
    try w.writeByte('\n');
}

const testing = std.testing;
const parser = @import("parser.zig");

test "introspect describes nested commands, flags, blocks and dependencies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\## > setup
        \\> Prepare things
        \\
        \\**OPTIONS**
        \\* port
        \\    * flags: -p --port
        \\    * type: number
        \\
        \\```sh
        \\echo "quoted"
        \\```
        \\
        \\### > server (port) [env]
        \\
        \\Requires: setup
        \\RunDeps: async
        \\
        \\```sh
        \\true
        \\```
        \\
    ;
    const root = (try parser.parseSource(arena, "/x/tasks.md", src)).root;
    var aw: Io.Writer.Allocating = .init(arena);
    try write(arena, &aw.writer, root, &.{"/x/tasks.md"}, "9.9.9");
    const out = aw.written();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out, .{});
    const obj = parsed.object;
    try testing.expectEqualStrings("9.9.9", obj.get("kevin").?.string);
    const setup = obj.get("commands").?.array.items[0].object;
    try testing.expectEqualStrings("setup", setup.get("name").?.string);
    try testing.expectEqualStrings("Prepare things", setup.get("description").?.string);
    try testing.expectEqualStrings("echo \"quoted\"\n", setup.get("blocks").?.array.items[0].object.get("code").?.string);
    try testing.expectEqualStrings("number", setup.get("flags").?.array.items[0].object.get("type").?.string);

    const server = setup.get("subcommands").?.array.items[0].object;
    try testing.expectEqual(@as(usize, 2), server.get("path").?.array.items.len);
    try testing.expectEqual(@as(usize, 2), server.get("args").?.array.items.len);
    try testing.expectEqualStrings("setup", server.get("requires").?.array.items[0].string);
    try testing.expectEqualStrings("async", server.get("run_deps").?.string);
    try testing.expect(server.get("jobs").?.null == {});
}
