//! `kevin --check-update`: asks GitHub for the latest release and compares it
//! with the running version. Nothing is downloaded or installed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const releases_url = "https://github.com/mtxr/kevin/releases/latest";

pub const Result = union(enum) {
    up_to_date: []const u8,
    available: []const u8,
    /// Why the check could not complete.
    failed: []const u8,
};

/// Parses "v1.2.3" / "1.2.3" (a pre-release suffix is ignored) into numbers.
fn parseVersion(s: []const u8) ?[3]u64 {
    var rest = if (std.mem.startsWith(u8, s, "v")) s[1..] else s;
    if (std.mem.indexOfAny(u8, rest, "-+")) |i| rest = rest[0..i];
    var out: [3]u64 = undefined;
    var it = std.mem.splitScalar(u8, rest, '.');
    for (&out) |*n| n.* = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    return out;
}

pub fn isNewer(current: []const u8, latest: []const u8) bool {
    const c = parseVersion(current) orelse return false;
    const l = parseVersion(latest) orelse return false;
    for (c, l) |a, b| {
        if (b > a) return true;
        if (b < a) return false;
    }
    return false;
}

/// Extracts the tag from the `Location` header of the /releases/latest redirect.
pub fn tagFromHeaders(headers: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, headers, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len < 9 or !std.ascii.eqlIgnoreCase(line[0..9], "location:")) continue;
        const url = std.mem.trim(u8, line[9..], " \t");
        const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse continue;
        const tag = url[slash + 1 ..];
        if (parseVersion(tag) != null) return tag;
    }
    return null;
}

pub fn check(gpa: Allocator, io: Io, current: []const u8) Allocator.Error!Result {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "curl", "-fsSI", "--max-time", "10", releases_url },
    }) catch |err| return .{ .failed = try std.fmt.allocPrint(gpa, "could not run curl: {t}", .{err}) };
    switch (res.term) {
        .exited => |c| if (c != 0) return .{ .failed = try std.fmt.allocPrint(gpa, "curl failed (exit {d}); are you online?", .{c}) },
        else => return .{ .failed = "curl was interrupted" },
    }
    const tag = tagFromHeaders(res.stdout) orelse return .{ .failed = "no release found" };
    return if (isNewer(current, tag)) .{ .available = tag } else .{ .up_to_date = tag };
}

const testing = std.testing;

test "isNewer compares numerically" {
    try testing.expect(isNewer("0.1.0", "v0.2.0"));
    try testing.expect(isNewer("0.9.0", "v0.10.0"));
    try testing.expect(isNewer("1.0.0", "v1.0.1"));
    try testing.expect(!isNewer("0.2.0", "v0.2.0"));
    try testing.expect(!isNewer("0.3.0", "v0.2.9"));
    try testing.expect(!isNewer("0.1.0", "garbage"));
    try testing.expect(isNewer("0.1.0", "v0.2.0-rc1"));
}

test "tagFromHeaders reads the redirect target" {
    const h = "HTTP/2 302 \r\nserver: github.com\r\nLocation: https://github.com/mtxr/kevin/releases/tag/v0.3.1\r\n\r\n";
    try testing.expectEqualStrings("v0.3.1", tagFromHeaders(h).?);
    try testing.expect(tagFromHeaders("HTTP/2 200\r\n\r\n") == null);
}
