//! `kevin --plugin-install owner/repo[@tag]`: downloads a plugin from a GitHub
//! release and registers it.
//!
//! By convention the repository is named `kevin-plugin-<name>` and its release
//! carries `<name>.wasm` and `<name>.wasm.sha256`, so the download URLs follow
//! from the argument and no GitHub API is involved:
//!
//!     https://github.com/<owner>/<repo>/releases/latest/download/<name>.wasm
//!     https://github.com/<owner>/<repo>/releases/download/<tag>/<name>.wasm
//!
//! Only those two files are fetched, over https, with a size limit. The
//! checksum guards the transfer; what is trusted is the repository's release,
//! the same as for any download. A release without a checksum is refused. The
//! plugin is then registered like one added with `--plugin-add`, and runs in
//! the sandbox either way.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const plugins = @import("plugins.zig");

/// Repositories that hold a kevin plugin are named `kevin-plugin-<name>`.
pub const repo_prefix = "kevin-plugin-";

pub const Spec = struct {
    owner: []const u8,
    repo: []const u8,
    /// The plugin name: the repository name without `repo_prefix`.
    name: []const u8,
    /// A release tag; null means the latest release.
    tag: ?[]const u8,
};

pub const SpecError = error{
    /// Not `owner/repo` or `owner/repo@tag`, or it holds characters GitHub does not allow.
    InvalidSpec,
    /// The repository is not named `kevin-plugin-<name>`.
    NotAPluginRepo,
};

fn allOf(text: []const u8, comptime extra: []const u8) bool {
    for (text) |ch| if (!(std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, extra, ch) != null)) return false;
    return true;
}

pub fn parseSpec(text: []const u8) SpecError!Spec {
    const at = std.mem.indexOfScalar(u8, text, '@');
    const repo_part = if (at) |i| text[0..i] else text;
    const tag: ?[]const u8 = if (at) |i| text[i + 1 ..] else null;
    const slash = std.mem.indexOfScalar(u8, repo_part, '/') orelse return error.InvalidSpec;
    const owner = repo_part[0..slash];
    const repo = repo_part[slash + 1 ..];

    if (owner.len == 0 or owner.len > 39 or !allOf(owner, "-")) return error.InvalidSpec;
    if (repo.len == 0 or repo.len > 100 or !allOf(repo, "._-")) return error.InvalidSpec;
    if (repo[0] == '.') return error.InvalidSpec;
    if (tag) |t| {
        if (t.len == 0 or t.len > 100 or !allOf(t, "._+-")) return error.InvalidSpec;
        if (t[0] == '.' or t[0] == '-') return error.InvalidSpec;
    }
    if (!std.mem.startsWith(u8, repo, repo_prefix)) return error.NotAPluginRepo;
    const name = repo[repo_prefix.len..];
    if (!plugins.validName(name)) return error.NotAPluginRepo;
    return .{ .owner = owner, .repo = repo, .name = name, .tag = tag };
}

/// `owner/repo` or `owner/repo@tag`, the form stored in the lockfile.
pub fn sourceString(arena: Allocator, spec: Spec) Allocator.Error![]const u8 {
    if (spec.tag) |t| return std.fmt.allocPrint(arena, "{s}/{s}@{s}", .{ spec.owner, spec.repo, t });
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ spec.owner, spec.repo });
}

/// URL of a release asset: `<name>.wasm` (`suffix` empty) or its checksum.
pub fn assetUrl(arena: Allocator, spec: Spec, suffix: []const u8) Allocator.Error![]const u8 {
    if (spec.tag) |t| return std.fmt.allocPrint(
        arena,
        "https://github.com/{s}/{s}/releases/download/{s}/{s}.wasm{s}",
        .{ spec.owner, spec.repo, t, spec.name, suffix },
    );
    return std.fmt.allocPrint(
        arena,
        "https://github.com/{s}/{s}/releases/latest/download/{s}.wasm{s}",
        .{ spec.owner, spec.repo, spec.name, suffix },
    );
}

/// The hash in a `.sha256` file: the first word, as `shasum -a 256` writes it
/// (`<hex>  <file>`).
pub fn parseChecksum(text: []const u8) ?[64]u8 {
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const first = words.next() orelse return null;
    if (first.len != 64) return null;
    var out: [64]u8 = undefined;
    for (first, 0..) |ch, i| {
        if (!std.ascii.isHex(ch)) return null;
        out[i] = std.ascii.toLower(ch);
    }
    return out;
}

pub const FetchError = Allocator.Error || error{
    /// The server has no such file (HTTP error).
    NotFound,
    TooLarge,
    /// curl is missing, or the network failed.
    Unavailable,
};

/// Downloads `url` into memory, refusing more than `max` bytes. A function
/// pointer so tests can install without a network.
pub const Fetch = *const fn (arena: Allocator, io: Io, url: []const u8, max: usize) FetchError![]const u8;

/// curl, restricted to https (also across redirects: GitHub serves release
/// files from its CDN), a bounded number of redirects, time and size.
pub fn curlFetch(arena: Allocator, io: Io, url: []const u8, max: usize) FetchError![]const u8 {
    const limit = try std.fmt.allocPrint(arena, "{d}", .{max});
    const res = std.process.run(arena, io, .{
        .argv = &.{
            "curl",           "-fsSL",
            "--proto",        "=https",
            "--proto-redir",  "=https",
            "--max-redirs",   "5",
            "--max-time",     "60",
            "--max-filesize", limit,
            url,
        },
        .stdout_limit = .limited(max),
        .stderr_limit = .limited(4096),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.TooLarge,
        else => return error.Unavailable,
    };
    switch (res.term) {
        .exited => |code| switch (code) {
            0 => return res.stdout,
            22 => return error.NotFound, // -f: HTTP 4xx/5xx
            63 => return error.TooLarge, // --max-filesize
            else => return error.Unavailable,
        },
        else => return error.Unavailable,
    }
}

pub const InstallError = error{
    /// The release has no `.sha256` next to the plugin.
    ChecksumMissing,
    /// The `.sha256` is not a SHA-256 hash.
    BadChecksumFile,
    /// The download does not match its `.sha256`.
    ChecksumMismatch,
    /// The release has no `<name>.wasm`.
    PluginMissing,
} || FetchError || plugins.Error;

/// Downloads and registers the plugin. The checksum is fetched first so a
/// release without one fails before the larger download.
pub fn install(arena: Allocator, io: Io, dir: []const u8, spec: Spec, fetch: Fetch) !plugins.Added {
    const sum_text = fetch(arena, io, try assetUrl(arena, spec, ".sha256"), 4096) catch |err| switch (err) {
        error.NotFound => return error.ChecksumMissing,
        else => |e| return e,
    };
    const want = parseChecksum(sum_text) orelse return error.BadChecksumFile;

    const bytes = fetch(arena, io, try assetUrl(arena, spec, ""), plugins.max_size) catch |err| switch (err) {
        error.NotFound => return error.PluginMissing,
        else => |e| return e,
    };
    const got = plugins.sha256Hex(bytes);
    if (!std.mem.eql(u8, &want, &got)) return error.ChecksumMismatch;

    return plugins.addBytes(arena, io, dir, spec.name, bytes, try sourceString(arena, spec));
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "specs: owner/repo[@tag], and only plugin repositories" {
    const a = try parseSpec("mtxr/kevin-plugin-node");
    try testing.expectEqualStrings("mtxr", a.owner);
    try testing.expectEqualStrings("kevin-plugin-node", a.repo);
    try testing.expectEqualStrings("node", a.name);
    try testing.expect(a.tag == null);

    const b = try parseSpec("some-org/kevin-plugin-just_2@v1.2.3-rc.1");
    try testing.expectEqualStrings("just_2", b.name);
    try testing.expectEqualStrings("v1.2.3-rc.1", b.tag.?);

    try testing.expectError(error.NotAPluginRepo, parseSpec("mtxr/kevin"));
    try testing.expectError(error.NotAPluginRepo, parseSpec("mtxr/kevin-plugin-"));
    try testing.expectError(error.NotAPluginRepo, parseSpec("mtxr/kevin-plugin-Node"));
}

test "specs reject anything that could change the URL" {
    for ([_][]const u8{
        "",
        "mtxr",
        "/kevin-plugin-x",
        "mtxr/",
        "mtxr/kevin-plugin-x@",
        "mtxr/kevin-plugin-x@v1/../x",
        "mtxr/kevin-plugin-x@v1?x=1",
        "mtxr/kevin-plugin-x@-o",
        "mtxr/kevin-plugin-x@.hidden",
        "m txr/kevin-plugin-x",
        "mtxr/kevin-plugin-x/extra",
        "https://github.com/mtxr/kevin-plugin-x",
        "mtxr/.kevin-plugin-x",
        "mtxr/kevin-plugin-x#frag",
        "mtxr/kevin-plugin-x%2e",
    }) |bad| {
        try testing.expect(std.meta.isError(parseSpec(bad)));
    }
}

test "urls follow the release layout" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const latest = try parseSpec("mtxr/kevin-plugin-node");
    try testing.expectEqualStrings(
        "https://github.com/mtxr/kevin-plugin-node/releases/latest/download/node.wasm",
        try assetUrl(arena, latest, ""),
    );
    const pinned = try parseSpec("mtxr/kevin-plugin-node@v0.1.0");
    try testing.expectEqualStrings(
        "https://github.com/mtxr/kevin-plugin-node/releases/download/v0.1.0/node.wasm.sha256",
        try assetUrl(arena, pinned, ".sha256"),
    );
    try testing.expectEqualStrings("mtxr/kevin-plugin-node@v0.1.0", try sourceString(arena, pinned));
    try testing.expectEqualStrings("mtxr/kevin-plugin-node", try sourceString(arena, latest));
}

test "a checksum file is read the way shasum writes it" {
    const h = plugins.sha256Hex("x");
    var line: [80]u8 = undefined;
    const text = try std.fmt.bufPrint(&line, "{s}  node.wasm\n", .{h});
    try testing.expectEqualStrings(&h, &parseChecksum(text).?);
    try testing.expectEqualStrings(&h, &parseChecksum(&h).?);
    try testing.expect(parseChecksum("") == null);
    try testing.expect(parseChecksum("deadbeef  node.wasm") == null);
    const bad: [64]u8 = @splat('g');
    try testing.expect(parseChecksum(&bad) == null);
}

// A fake release: what `fetch` returns for the checksum and the plugin.
const fake_module = "\x00asm\x01\x00\x00\x00";
var fake_checksum: []const u8 = "";
var fake_missing_sum = false;
var fake_missing_wasm = false;

fn fakeFetch(_: Allocator, _: Io, url: []const u8, _: usize) FetchError![]const u8 {
    if (std.mem.endsWith(u8, url, ".sha256")) return if (fake_missing_sum) error.NotFound else fake_checksum;
    return if (fake_missing_wasm) error.NotFound else fake_module;
}

test "install downloads, checks and registers, remembering the source" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const reg = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/registry", .{tmp.sub_path});
    const spec = try parseSpec("me/kevin-plugin-demo@v1.0.0");

    fake_missing_sum = false;
    fake_missing_wasm = false;
    const good = plugins.sha256Hex(fake_module);
    fake_checksum = try std.fmt.allocPrint(arena, "{s}  demo.wasm\n", .{good});

    const added = try install(arena, testing.io, reg, spec, fakeFetch);
    try testing.expect(added.new);
    try testing.expectEqualStrings("demo", added.entry.name);
    try testing.expectEqualStrings("me/kevin-plugin-demo@v1.0.0", added.entry.source.?);
    try testing.expectEqualStrings(fake_module, try plugins.load(arena, testing.io, reg, "demo"));
}

test "install refuses what it cannot verify, and registers nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const reg = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/registry", .{tmp.sub_path});
    const spec = try parseSpec("me/kevin-plugin-demo");

    // The download does not match its checksum.
    fake_missing_sum = false;
    fake_missing_wasm = false;
    fake_checksum = &plugins.sha256Hex("something else");
    try testing.expectError(error.ChecksumMismatch, install(arena, testing.io, reg, spec, fakeFetch));
    // The checksum file is not a hash.
    fake_checksum = "not a hash";
    try testing.expectError(error.BadChecksumFile, install(arena, testing.io, reg, spec, fakeFetch));
    // No checksum in the release.
    fake_missing_sum = true;
    try testing.expectError(error.ChecksumMissing, install(arena, testing.io, reg, spec, fakeFetch));
    // No plugin in the release.
    fake_missing_sum = false;
    fake_checksum = &plugins.sha256Hex(fake_module);
    fake_missing_wasm = true;
    try testing.expectError(error.PluginMissing, install(arena, testing.io, reg, spec, fakeFetch));

    try testing.expectEqual(@as(usize, 0), (try plugins.readLock(arena, testing.io, reg)).len);
}
