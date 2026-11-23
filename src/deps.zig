//! Dependency graph: turns `Requires:` entries into a tree of nodes and runs
//! it, sequentially (`RunDeps: sync`, the default) or concurrently
//! (`RunDeps: async`), with a cap on the number of scripts running at once.

const std = @import("std");
const ast = @import("ast.zig");
const cli = @import("cli.zig");
const runner = @import("runner.zig");
const proc = @import("proc.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Command = ast.Command;

pub const Node = struct {
    cmd: *const Command,
    /// Positional arguments and flags of this invocation, as environment variables.
    env: []const cli.EnvPair,
    deps: []const *Node,
    async_deps: bool,
    /// Max number of dependencies of this node running at once (`Jobs:`).
    jobs: ?u32,
    /// Shared between every requirer; runs a single time per invocation.
    once: bool,

    claimed: std.atomic.Value(bool) = .init(false),
    done: Io.Event = .unset,
    code: u8 = 0,
};

pub const BuildError = Allocator.Error || error{Invalid};

/// Resolves the dependency tree of a command before anything runs, so that
/// unknown tasks, bad arguments and cycles fail up front.
pub const Builder = struct {
    arena: Allocator,
    root: *const Command,
    /// Filled when `build` returns `error.Invalid`.
    err: []const u8 = "",
    once_nodes: std.StringHashMapUnmanaged(*Node) = .empty,
    stack: std.ArrayList(*const Command) = .empty,

    pub fn build(self: *Builder, cmd: *const Command, env: []const cli.EnvPair) BuildError!*Node {
        const spec = cmd.deps;

        for (self.stack.items) |c| {
            if (c != cmd) continue;
            var path: std.ArrayList(u8) = .empty;
            for (self.stack.items) |s| try path.print(self.arena, "{s} -> ", .{s.name});
            try path.appendSlice(self.arena, cmd.name);
            self.err = try std.fmt.allocPrint(self.arena, "dependency cycle: {s}", .{path.items});
            return error.Invalid;
        }

        var key: []const u8 = "";
        if (spec.run_once) {
            var k: std.ArrayList(u8) = .empty;
            try k.print(self.arena, "{d}", .{@intFromPtr(cmd)});
            for (env) |p| try k.print(self.arena, "|{s}={s}", .{ p.name, p.value });
            key = k.items;
            if (self.once_nodes.get(key)) |existing| return existing;
        }

        try self.stack.append(self.arena, cmd);
        defer _ = self.stack.pop();

        var deps: std.ArrayList(*Node) = .empty;
        for (spec.requires.items) |entry| {
            const raw = try splitWords(self.arena, entry);
            if (raw.len == 0) continue;
            const words = try self.arena.alloc([]const u8, raw.len);
            for (raw, words) |r, *w| w.* = try expandVars(self.arena, r, env);

            const r = try cli.resolve(self.arena, self.root, words);
            if (r.cmd == self.root) {
                self.err = try std.fmt.allocPrint(self.arena, "unknown task '{s}' in the Requires of '{s}'", .{ words[0], cmd.name });
                return error.Invalid;
            }
            if (!r.cmd.hasWork()) {
                self.err = try std.fmt.allocPrint(self.arena, "'{s}', required by '{s}', has nothing to run", .{ r.cmd.name, cmd.name });
                return error.Invalid;
            }
            var msg: []const u8 = "";
            const inv = cli.parseInvocation(self.arena, r.cmd, r.rest, &msg) catch |e| switch (e) {
                error.Usage => {
                    self.err = try std.fmt.allocPrint(self.arena, "Requires '{s}' of '{s}': {s}", .{ entry, cmd.name, msg });
                    return error.Invalid;
                },
                else => |oom| return oom,
            };
            try deps.append(self.arena, try self.build(r.cmd, inv.env));
        }

        const node = try self.arena.create(Node);
        node.* = .{
            .cmd = cmd,
            .env = env,
            .deps = deps.items,
            .async_deps = spec.run_deps == .async,
            .jobs = spec.jobs,
            .once = spec.run_once,
        };
        if (spec.run_once) try self.once_nodes.put(self.arena, key, node);
        return node;
    }
};

/// Splits on whitespace, honouring '...' and "..." quotes.
pub fn splitWords(arena: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var in_word = false;
    var quote: u8 = 0;
    for (s) |c| {
        if (quote != 0) {
            if (c == quote) quote = 0 else try cur.append(arena, c);
        } else if (c == '\'' or c == '"') {
            quote = c;
            in_word = true;
        } else if (c == ' ' or c == '\t') {
            if (in_word) {
                try words.append(arena, cur.items);
                cur = .empty;
                in_word = false;
            }
        } else {
            try cur.append(arena, c);
            in_word = true;
        }
    }
    if (in_word) try words.append(arena, cur.items);
    return words.items;
}

fn envValue(env: []const cli.EnvPair, name: []const u8) []const u8 {
    for (env) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
    return "";
}

/// Expands `$name` and `${name}` from the invoking command's arguments and
/// flags; unknown names expand to nothing.
pub fn expandVars(arena: Allocator, word: []const u8, env: []const cli.EnvPair) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, word, '$') == null) return word;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < word.len) {
        if (word[i] != '$') {
            try out.append(arena, word[i]);
            i += 1;
            continue;
        }
        if (i + 1 < word.len and word[i + 1] == '{') {
            if (std.mem.indexOfScalarPos(u8, word, i + 2, '}')) |close| {
                try out.appendSlice(arena, envValue(env, word[i + 2 .. close]));
                i = close + 1;
                continue;
            }
        }
        var j = i + 1;
        while (j < word.len and (std.ascii.isAlphanumeric(word[j]) or word[j] == '_')) j += 1;
        if (j == i + 1) {
            try out.append(arena, '$');
            i += 1;
            continue;
        }
        try out.appendSlice(arena, envValue(env, word[i + 1 .. j]));
        i = j;
    }
    return out.items;
}

// ---------------------------------------------------------------- execution

pub const Ctx = struct {
    arena: Allocator,
    io: Io,
    base_env: *const std.process.Environ.Map,
    exe: []const u8,
    verbose: bool,
    jobs: usize,
    /// One permit per script allowed to run at the same time.
    slots: Io.Semaphore,
};

/// How many kevin processes are already above this one (`KEVIN_DEPTH` of the
/// environment kevin was started in). Set once by main; children get depth + 1.
pub var depth: u32 = 0;

/// Nesting limit: a task that keeps calling itself through `$KEVIN` stops here.
pub const max_depth: u32 = 32;

/// Variables kevin adds on top of the inherited environment for `node`.
pub fn injectedVars(
    arena: Allocator,
    exe: []const u8,
    cmd: *const Command,
    env: []const cli.EnvPair,
    verbose: bool,
    jobs: usize,
) Allocator.Error![]const cli.EnvPair {
    var out: std.ArrayList(cli.EnvPair) = .empty;
    try out.appendSlice(arena, env);
    try out.append(arena, .{ .name = "KEVIN", .value = try std.fmt.allocPrint(arena, "{s} --file {s}", .{ exe, cmd.source_path }) });
    try out.append(arena, .{ .name = "KEVIN_DIR", .value = std.fs.path.dirname(cmd.source_path) orelse "." });
    try out.append(arena, .{ .name = "KEVIN_JOBS", .value = try std.fmt.allocPrint(arena, "{d}", .{jobs}) });
    try out.append(arena, .{ .name = "KEVIN_DEPTH", .value = try std.fmt.allocPrint(arena, "{d}", .{depth + 1}) });
    if (verbose) {
        try out.append(arena, .{ .name = "verbose", .value = "true" });
        try out.append(arena, .{ .name = "KEVIN_VERBOSE", .value = "true" });
    }
    return out.items;
}

/// Runs dependencies, then the node's own code blocks. Returns the exit code.
pub fn execute(ctx: *Ctx, node: *Node) u8 {
    if (node.once and node.claimed.swap(true, .acq_rel)) {
        node.done.waitUncancelable(ctx.io);
        return node.code;
    }
    const code = executeOnce(ctx, node);
    node.code = code;
    if (node.once) node.done.set(ctx.io);
    return code;
}

fn executeOnce(ctx: *Ctx, node: *Node) u8 {
    if (node.deps.len > 0) {
        const code = if (node.async_deps) runAsync(ctx, node) else runSync(ctx, node);
        if (code != 0) return code;
    }
    if (node.cmd.blocks.items.len == 0) return 0;

    ctx.slots.waitUncancelable(ctx.io);
    defer ctx.slots.post(ctx.io);

    const vars = injectedVars(ctx.arena, ctx.exe, node.cmd, node.env, ctx.verbose, ctx.jobs) catch return 1;
    var env = ctx.base_env.clone(ctx.arena) catch return 1;
    for (vars) |p| env.put(p.name, p.value) catch return 1;
    return runner.runCommand(ctx.arena, ctx.io, node.cmd, &env, ctx.verbose) catch 1;
}

fn runSync(ctx: *Ctx, node: *Node) u8 {
    for (node.deps) |dep| {
        if (ctx.verbose) std.debug.print("+ {s} requires {s}\n", .{ node.cmd.name, dep.cmd.name });
        const code = execute(ctx, dep);
        if (code != 0) return code;
    }
    return 0;
}

/// State shared by the tasks of one `RunDeps: async` group.
const Group = struct {
    /// Dependencies of the group are cancelled through this scope.
    scope: proc.Scope,
    /// Max number of group members running at once (`Jobs:`).
    slots: Io.Semaphore,
    /// Exit code of the first dependency that failed (0 = none yet).
    first_failure: std.atomic.Value(u8) = .init(0),
};

fn asyncRun(ctx: *Ctx, dep: *Node, group: *Group) Io.Cancelable!void {
    group.slots.waitUncancelable(ctx.io);
    defer group.slots.post(ctx.io);
    // Fail-fast: a sibling already failed, so this one never starts.
    if (group.scope.isCancelled()) return;

    const prev = proc.enterScope(&group.scope);
    defer proc.leaveScope(prev);
    const code = execute(ctx, dep);
    if (code != 0 and group.first_failure.cmpxchgStrong(0, code, .acq_rel, .acquire) == null) {
        // First failure: stop the siblings that are still running.
        group.scope.cancel();
    }
}

/// Starts every dependency (at most `Jobs:` at a time) and waits for all of
/// them. When one fails, the running siblings get SIGTERM, pending ones do not
/// start, and the exit code of the first failure is returned.
fn runAsync(ctx: *Ctx, node: *Node) u8 {
    var io_group: Io.Group = .init;
    var group: Group = .{
        .scope = .{ .parent = proc.currentScope() },
        .slots = .{ .permits = node.jobs orelse node.deps.len },
    };
    for (node.deps) |dep| {
        if (ctx.verbose) std.debug.print("+ {s} requires {s} (async)\n", .{ node.cmd.name, dep.cmd.name });
        io_group.async(ctx.io, asyncRun, .{ ctx, dep, &group });
    }
    io_group.await(ctx.io) catch {};
    const first = group.first_failure.load(.acquire);
    if (first != 0) return first;
    // Nothing failed by itself, but the whole group may have been stopped from outside.
    if (group.scope.isCancelled()) return proc.stopped_code;
    return 0;
}

/// Number of nodes in the tree below `node` (shared `Run: once` nodes count once).
/// Bounds how many threads the async runtime may need.
pub fn countNodes(arena: Allocator, node: *const Node) Allocator.Error!usize {
    var seen: std.AutoHashMapUnmanaged(*const Node, void) = .empty;
    return countInto(arena, &seen, node);
}

fn countInto(arena: Allocator, seen: *std.AutoHashMapUnmanaged(*const Node, void), node: *const Node) Allocator.Error!usize {
    if (node.once) {
        if ((try seen.getOrPut(arena, node)).found_existing) return 0;
    }
    var n: usize = 1;
    for (node.deps) |d| n += try countInto(arena, seen, d);
    return n;
}

// -------------------------------------------------------------------- tests

const testing = std.testing;
const parser = @import("parser.zig");

fn buildFor(arena: Allocator, src: []const u8, name: []const u8, args: []const cli.EnvPair) !struct { root: *Command, builder: Builder, node: ?*Node } {
    const root = (try parser.parseSource(arena, "/t.md", src)).root;
    var b: Builder = .{ .arena = arena, .root = root };
    const node = b.build(root.find(name).?, args) catch |e| switch (e) {
        error.Invalid => null,
        else => |oom| return oom,
    };
    return .{ .root = root, .builder = b, .node = node };
}

test "splitWords and expandVars" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const w = try splitWords(arena, "build  'web app' \"x y\" plain");
    try testing.expectEqual(@as(usize, 4), w.len);
    try testing.expectEqualStrings("web app", w[1]);
    try testing.expectEqualStrings("x y", w[2]);

    const env = [_]cli.EnvPair{.{ .name = "target", .value = "prod" }};
    try testing.expectEqualStrings("deploy-prod", try expandVars(arena, "deploy-$target", &env));
    try testing.expectEqualStrings("prod/", try expandVars(arena, "${target}/", &env));
    try testing.expectEqualStrings("", try expandVars(arena, "$missing", &env));
    try testing.expectEqualStrings("cost $", try expandVars(arena, "cost $", &env));
}

test "dependency tree with arguments, order and once-dedup" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\## > setup
        \\
        \\Run: once
        \\
        \\```sh
        \\echo setup
        \\```
        \\
        \\## > build (target)
        \\
        \\Requires: setup
        \\
        \\```sh
        \\echo build
        \\```
        \\
        \\## > lint
        \\
        \\Requires: setup
        \\
        \\```sh
        \\echo lint
        \\```
        \\
        \\## > ship (target)
        \\
        \\Requires: build $target, lint
        \\RunDeps: async
        \\Jobs: 1
        \\
        \\```sh
        \\echo ship
        \\```
        \\
    ;
    const r = try buildFor(arena, src, "ship", &.{.{ .name = "target", .value = "prod" }});
    const ship = r.node.?;
    try testing.expect(ship.async_deps);
    try testing.expectEqual(@as(?u32, 1), ship.jobs);
    try testing.expectEqual(@as(usize, 2), ship.deps.len);
    try testing.expectEqualStrings("build", ship.deps[0].cmd.name);
    try testing.expectEqualStrings("target", ship.deps[0].env[0].name);
    try testing.expectEqualStrings("prod", ship.deps[0].env[0].value);
    // `setup` is `Run: once`, so both requirers share one node.
    try testing.expect(ship.deps[0].deps[0] == ship.deps[1].deps[0]);
}

test "invalid requirements fail before anything runs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cycle = try buildFor(arena, "## > a\n\nRequires: b\n\n```sh\ntrue\n```\n\n## > b\n\nRequires: a\n\n```sh\ntrue\n```\n", "a", &.{});
    try testing.expect(cycle.node == null);
    try testing.expectEqualStrings("dependency cycle: a -> b -> a", cycle.builder.err);

    const unknown = try buildFor(arena, "## > a\n\nRequires: ghost\n\n```sh\ntrue\n```\n", "a", &.{});
    try testing.expect(unknown.node == null);
    try testing.expect(std.mem.indexOf(u8, unknown.builder.err, "unknown task 'ghost'") != null);

    const badargs = try buildFor(arena, "## > a\n\nRequires: b\n\n```sh\ntrue\n```\n\n## > b (x)\n\n```sh\ntrue\n```\n", "a", &.{});
    try testing.expect(badargs.node == null);
    try testing.expect(std.mem.indexOf(u8, badargs.builder.err, "missing required argument <x>") != null);
}

test "injected variables carry the nesting depth" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = (try parser.parseSource(arena, "/t.md", "## > a\n\n```sh\ntrue\n```\n")).root;
    const saved = depth;
    defer depth = saved;
    depth = 4;
    const vars = try injectedVars(arena, "/bin/kevin", root.find("a").?, &.{}, false, 2);
    for (vars) |v| {
        if (std.mem.eql(u8, v.name, "KEVIN_DEPTH")) return try testing.expectEqualStrings("5", v.value);
    }
    return error.TestUnexpectedResult;
}

test "countNodes counts shared once-nodes a single time" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\## > setup
        \\
        \\Run: once
        \\
        \\```sh
        \\true
        \\```
        \\
        \\## > a
        \\
        \\Requires: setup
        \\
        \\```sh
        \\true
        \\```
        \\
        \\## > b
        \\
        \\Requires: setup, a
        \\
        \\```sh
        \\true
        \\```
        \\
    ;
    const r = try buildFor(arena, src, "b", &.{});
    // b, setup (once), a (setup already counted).
    try testing.expectEqual(@as(usize, 3), try countNodes(arena, r.node.?));
}
