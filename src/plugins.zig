//! The local plugin registry: `.wasm` converters the user has added to this
//! machine, stored by name next to a lockfile with their sha256.
//!
//!     <dir>/<name>.wasm
//!     <dir>/plugins.lock        one `<name> <sha256 hex> [<source>]` per line
//!
//! `<dir>` is `$KEVIN_PLUGIN_DIR`, else `$XDG_CONFIG_HOME/kevin/plugins`,
//! else `~/.config/kevin/plugins`. Nothing here touches the network: a plugin
//! gets in only as bytes the caller hands over (a file with `--plugin-add`, a
//! download checked by `install.zig`), and it is checked against its recorded
//! hash every time it is loaded, so a file that changed on disk afterwards is
//! refused rather than run. `<source>` (`owner/repo[@tag]`) says where an
//! installed plugin came from; it is informational and never trusted.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const max_size = 8 * 1024 * 1024;
pub const lock_name = "plugins.lock";
const wasm_magic = "\x00asm";

pub const Entry = struct {
    name: []const u8,
    /// Lowercase hex sha256 of the `.wasm` file.
    hash: []const u8,
    /// Where it was installed from (`owner/repo[@tag]`); null for `--plugin-add`.
    source: ?[]const u8 = null,
};

pub const Error = error{
    /// A name must match `[a-z0-9][a-z0-9_-]*` (at most 64 characters).
    InvalidName,
    NotWasm,
    TooLarge,
    /// A different file is already registered under that name.
    AlreadyRegistered,
    NotRegistered,
    /// The file on disk no longer matches the hash recorded when it was added.
    Modified,
    CorruptLock,
};

// ------------------------------------------------------------------- pure

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name, 0..) |ch, i| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or
            (i > 0 and (ch == '_' or ch == '-'));
        if (!ok) return false;
    }
    return true;
}

/// `path/to/npm.wasm` -> `npm`, when that is a valid plugin name.
pub fn nameFromPath(path: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(path);
    const stem = if (std.mem.endsWith(u8, base, ".wasm")) base[0 .. base.len - ".wasm".len] else base;
    return if (validName(stem)) stem else null;
}

/// A `source` is one token of `[A-Za-z0-9._@/+-]`, so the lock stays one line.
fn validSource(source: []const u8) bool {
    if (source.len == 0 or source.len > 200) return false;
    for (source) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "._@/+-", ch) != null)) return false;
    }
    return true;
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Where the registry lives. `env` is the process environment.
pub fn dirPath(arena: Allocator, env: *const std.process.Environ.Map) Allocator.Error!?[]const u8 {
    if (env.get("KEVIN_PLUGIN_DIR")) |d| if (d.len > 0) return d;
    if (env.get("XDG_CONFIG_HOME")) |x| if (x.len > 0)
        return try std.fs.path.join(arena, &.{ x, "kevin", "plugins" });
    if (env.get("HOME")) |h| if (h.len > 0)
        return try std.fs.path.join(arena, &.{ h, ".config", "kevin", "plugins" });
    return null;
}

pub fn parseLock(arena: Allocator, text: []const u8) (Error || Allocator.Error)![]const Entry {
    var out: std.ArrayList(Entry) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var parts = std.mem.tokenizeAny(u8, line, " \t");
        const name = parts.next() orelse return error.CorruptLock;
        const hash = parts.next() orelse return error.CorruptLock;
        const source = parts.next();
        if (parts.next() != null or !validName(name) or hash.len != 64) return error.CorruptLock;
        if (source) |src| if (!validSource(src)) return error.CorruptLock;
        for (hash) |ch| if (!std.ascii.isHex(ch)) return error.CorruptLock;
        try out.append(arena, .{ .name = name, .hash = try std.ascii.allocLowerString(arena, hash), .source = source });
    }
    return out.items;
}

pub fn formatLock(arena: Allocator, entries: []const Entry) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "# Written by kevin: plugin name, the sha256 of its .wasm and, if installed, its source.\n");
    for (entries) |e| {
        try out.print(arena, "{s} {s}", .{ e.name, e.hash });
        if (e.source) |src| try out.print(arena, " {s}", .{src});
        try out.append(arena, '\n');
    }
    return out.items;
}

fn find(entries: []const Entry, name: []const u8) ?Entry {
    for (entries) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

// --------------------------------------------------------------------- I/O

fn wasmPath(arena: Allocator, dir: []const u8, name: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(arena, &.{ dir, try std.fmt.allocPrint(arena, "{s}.wasm", .{name}) });
}

/// The registered plugins; none when nothing was ever added.
pub fn readLock(arena: Allocator, io: Io, dir: []const u8) ![]const Entry {
    const path = try std.fs.path.join(arena, &.{ dir, lock_name });
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    return parseLock(arena, text);
}

fn writeLock(arena: Allocator, io: Io, dir: []const u8, entries: []const Entry) !void {
    const path = try std.fs.path.join(arena, &.{ dir, lock_name });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try formatLock(arena, entries) });
}

pub const Added = struct {
    entry: Entry,
    /// False when the same file was already registered.
    new: bool,
};

/// Registers the `.wasm` at `src_path` under the name of its file.
pub fn add(arena: Allocator, io: Io, dir: []const u8, src_path: []const u8) !Added {
    const name = nameFromPath(src_path) orelse return error.InvalidName;
    const bytes = Io.Dir.cwd().readFileAlloc(io, src_path, arena, .limited(max_size)) catch |err| switch (err) {
        error.StreamTooLong => return error.TooLarge,
        else => return err,
    };
    return addBytes(arena, io, dir, name, bytes, null);
}

/// Registers `bytes` as the plugin `name`. `source` records where they came
/// from. The same bytes again are not an error; different bytes under a taken
/// name are (`error.AlreadyRegistered`).
pub fn addBytes(arena: Allocator, io: Io, dir: []const u8, name: []const u8, bytes: []const u8, source: ?[]const u8) !Added {
    if (!validName(name)) return error.InvalidName;
    if (source) |src| if (!validSource(src)) return error.InvalidName;
    if (bytes.len > max_size) return error.TooLarge;
    if (!std.mem.startsWith(u8, bytes, wasm_magic)) return error.NotWasm;
    const hash = try arena.dupe(u8, &sha256Hex(bytes));

    const current = try readLock(arena, io, dir);
    if (find(current, name)) |existing| {
        if (std.mem.eql(u8, existing.hash, hash)) return .{ .entry = existing, .new = false };
        return error.AlreadyRegistered;
    }

    try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try wasmPath(arena, dir, name), .data = bytes });
    const entry: Entry = .{ .name = name, .hash = hash, .source = if (source) |src| try arena.dupe(u8, src) else null };
    var all: std.ArrayList(Entry) = .empty;
    try all.appendSlice(arena, current);
    try all.append(arena, entry);
    try writeLock(arena, io, dir, all.items);
    return .{ .entry = entry, .new = true };
}

pub fn remove(arena: Allocator, io: Io, dir: []const u8, name: []const u8) !void {
    const current = try readLock(arena, io, dir);
    if (find(current, name) == null) return error.NotRegistered;
    var rest: std.ArrayList(Entry) = .empty;
    for (current) |e| if (!std.mem.eql(u8, e.name, name)) try rest.append(arena, e);
    try writeLock(arena, io, dir, rest.items);
    Io.Dir.cwd().deleteFile(io, try wasmPath(arena, dir, name)) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// The bytes of a registered plugin, after checking them against the lockfile.
/// `error.NotRegistered` also covers a name that is not a plugin at all.
pub fn load(arena: Allocator, io: Io, dir: []const u8, name: []const u8) ![]const u8 {
    if (!validName(name)) return error.NotRegistered;
    const entry = find(try readLock(arena, io, dir), name) orelse return error.NotRegistered;
    const bytes = Io.Dir.cwd().readFileAlloc(io, try wasmPath(arena, dir, name), arena, .limited(max_size)) catch |err| switch (err) {
        error.FileNotFound => return error.NotRegistered,
        error.StreamTooLong => return error.Modified,
        else => return err,
    };
    if (!std.mem.eql(u8, &sha256Hex(bytes), entry.hash)) return error.Modified;
    return bytes;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "plugin names" {
    try testing.expect(validName("npm"));
    try testing.expect(validName("just-2_x"));
    try testing.expect(!validName(""));
    try testing.expect(!validName("-npm"));
    try testing.expect(!validName("NPM"));
    try testing.expect(!validName("a/b"));
    try testing.expect(!validName("a b"));
    const long: [65]u8 = @splat('x');
    try testing.expect(!validName(&long));
    try testing.expectEqualStrings("npm", nameFromPath("some/dir/npm.wasm").?);
    try testing.expect(nameFromPath("some/dir/Not Valid.wasm") == null);
}

test "the registry directory: override, then XDG, then HOME" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expect((try dirPath(arena, &env)) == null);
    try env.put("HOME", "/home/u");
    try testing.expectEqualStrings(
        try std.fs.path.join(arena, &.{ "/home/u", ".config", "kevin", "plugins" }),
        (try dirPath(arena, &env)).?,
    );
    try env.put("XDG_CONFIG_HOME", "/xdg");
    try testing.expectEqualStrings(
        try std.fs.path.join(arena, &.{ "/xdg", "kevin", "plugins" }),
        (try dirPath(arena, &env)).?,
    );
    try env.put("KEVIN_PLUGIN_DIR", "/custom");
    try testing.expectEqualStrings("/custom", (try dirPath(arena, &env)).?);
    try env.put("KEVIN_PLUGIN_DIR", "");
    try testing.expectEqualStrings(
        try std.fs.path.join(arena, &.{ "/xdg", "kevin", "plugins" }),
        (try dirPath(arena, &env)).?,
    );
}

test "the lockfile round-trips and rejects malformed lines" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const h = sha256Hex("x");
    const text = try formatLock(arena, &.{.{ .name = "npm", .hash = &h }});
    const back = try parseLock(arena, text);
    try testing.expectEqual(@as(usize, 1), back.len);
    try testing.expectEqualStrings("npm", back[0].name);
    try testing.expectEqualStrings(&h, back[0].hash);
    try testing.expectError(error.CorruptLock, parseLock(arena, "npm\n"));
    try testing.expectError(error.CorruptLock, parseLock(arena, "npm deadbeef\n"));
    const zeros: [64]u8 = @splat('0');
    try testing.expectError(error.CorruptLock, parseLock(arena, try std.fmt.allocPrint(arena, "Bad {s}\n", .{zeros})));
}

test "add, load, change detection and remove" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const reg = try std.fs.path.join(arena, &.{ base, "registry" });
    const src = try std.fs.path.join(arena, &.{ base, "demo.wasm" });
    const module = "\x00asm\x01\x00\x00\x00";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "demo.wasm", .data = module });

    const first = try add(arena, testing.io, reg, src);
    try testing.expect(first.new);
    try testing.expectEqualStrings("demo", first.entry.name);
    try testing.expectEqualStrings(module, try load(arena, testing.io, reg, "demo"));
    // The same file again is not an error and changes nothing.
    try testing.expect(!(try add(arena, testing.io, reg, src)).new);

    // Another file under the same name needs an explicit remove first.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "demo.wasm", .data = module ++ "x" });
    try testing.expectError(error.AlreadyRegistered, add(arena, testing.io, reg, src));

    // Editing the stored copy is noticed.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "registry/demo.wasm", .data = module ++ "evil" });
    try testing.expectError(error.Modified, load(arena, testing.io, reg, "demo"));

    try remove(arena, testing.io, reg, "demo");
    try testing.expectError(error.NotRegistered, load(arena, testing.io, reg, "demo"));
    try testing.expectError(error.NotRegistered, remove(arena, testing.io, reg, "demo"));
    // After removing, the changed file registers normally.
    try testing.expect((try add(arena, testing.io, reg, src)).new);
}

test "only WebAssembly files can be added" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "text.wasm", .data = "hello" });
    try testing.expectError(error.NotWasm, add(arena, testing.io, base, try std.fs.path.join(arena, &.{ base, "text.wasm" })));
    try testing.expectError(error.InvalidName, add(arena, testing.io, base, "Bad Name.wasm"));
}

test "an installed plugin remembers where it came from" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const reg = try std.fs.path.join(arena, &.{ base, "registry" });
    const module = "\x00asm\x01\x00\x00\x00";

    const added = try addBytes(arena, testing.io, reg, "demo", module, "me/kevin-plugin-demo@v1.2.0");
    try testing.expect(added.new);
    const entries = try readLock(arena, testing.io, reg);
    try testing.expectEqualStrings("me/kevin-plugin-demo@v1.2.0", entries[0].source.?);
    try testing.expectEqualStrings(module, try load(arena, testing.io, reg, "demo"));

    // A lock line with a source that is not one safe token is corrupt.
    const h = sha256Hex("x");
    try testing.expectError(error.CorruptLock, parseLock(arena, try std.fmt.allocPrint(arena, "demo {s} a;b\n", .{h})));
    try testing.expectError(error.CorruptLock, parseLock(arena, try std.fmt.allocPrint(arena, "demo {s} a b\n", .{h})));
    try testing.expectError(error.InvalidName, addBytes(arena, testing.io, reg, "demo2", module, "a b"));
    try testing.expectError(error.NotWasm, addBytes(arena, testing.io, reg, "demo3", "nope", null));
}
