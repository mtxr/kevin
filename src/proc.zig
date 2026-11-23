//! Process-wide state shared by every running task: the registry of live
//! children, signal forwarding, cancellation scopes (fail-fast of async
//! groups) and the private temp directory that holds the script files.
//!
//! The registry is a fixed array of atomics so that the signal handler can
//! walk it without locks or allocation (async-signal-safe).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const posix = std.posix;

const is_windows = builtin.os.tag == .windows;
const has_signals = !is_windows and posix.Sigaction != void;

/// Maximum number of simultaneously tracked children. Children beyond this
/// still run, they just are not reached by signal forwarding.
const max_children = 4096;

/// Child identifier: the pid on POSIX, the process handle on Windows. 0 means free.
var slot_ids: [max_children]std.atomic.Value(usize) = @splat(.init(0));
/// Cancellation scope of each slot. Only touched while holding `lock`.
var slot_scopes: [max_children]?*const Scope = @splat(null);
var lock_flag: std.atomic.Value(bool) = .init(false);

/// Whether children are started in their own process group, so that signals
/// reach the whole subtree (not only the direct child). Off when stdin is a
/// terminal: a background group cannot read the terminal.
var use_groups: bool = false;

/// First signal received (0 = none) and the number received so far.
var first_signal: std.atomic.Value(i32) = .init(0);
var signal_count: std.atomic.Value(u32) = .init(0);

fn lock() void {
    while (lock_flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlock() void {
    lock_flag.store(false, .release);
}

// ------------------------------------------------------------------- scopes

/// A cancellation scope: the dependencies of one `RunDeps: async` group.
/// Cancelling a scope also cancels every scope nested in it.
pub const Scope = struct {
    parent: ?*const Scope = null,
    cancelled: std.atomic.Value(bool) = .init(false),

    pub fn isCancelled(s: *const Scope) bool {
        var cur: ?*const Scope = s;
        while (cur) |c| : (cur = c.parent) {
            if (c.cancelled.load(.acquire)) return true;
        }
        return false;
    }

    fn contains(s: *const Scope, outer: *const Scope) bool {
        var cur: ?*const Scope = s;
        while (cur) |c| : (cur = c.parent) {
            if (c == outer) return true;
        }
        return false;
    }

    /// Marks the scope cancelled and asks every live child inside it to stop.
    pub fn cancel(s: *const Scope) void {
        @constCast(&s.cancelled).store(true, .release);
        lock();
        defer unlock();
        for (&slot_ids, 0..) |*slot, i| {
            const id = slot.load(.acquire);
            if (id == 0) continue;
            const owner = slot_scopes[i] orelse continue;
            if (owner.contains(s)) deliver(id, .TERM);
        }
    }
};

/// The scope the current thread works for (set around each async dependency).
threadlocal var current: ?*const Scope = null;

pub fn currentScope() ?*const Scope {
    return current;
}

/// Makes `scope` the current scope; returns the previous one for `leaveScope`.
pub fn enterScope(scope: *const Scope) ?*const Scope {
    const prev = current;
    current = scope;
    return prev;
}

pub fn leaveScope(prev: ?*const Scope) void {
    current = prev;
}

/// True when the current thread must not start (or continue) work: a signal
/// arrived or the enclosing async group failed.
pub fn shouldStop() bool {
    if (first_signal.load(.acquire) != 0) return true;
    if (current) |s| return s.isCancelled();
    return false;
}

// ------------------------------------------------------------------ children

pub const Tracked = struct { slot: ?usize };

/// Adds a freshly spawned child to the registry. When a stop was requested
/// in the meantime the child is terminated right away.
pub fn track(id: usize) Tracked {
    lock();
    var found: ?usize = null;
    for (&slot_ids, 0..) |*slot, i| {
        if (slot.load(.monotonic) == 0) {
            slot_scopes[i] = current;
            slot.store(id, .release);
            found = i;
            break;
        }
    }
    unlock();
    // Close the race with a signal or cancel that arrived before registration.
    if (first_signal.load(.acquire) != 0) {
        deliver(id, @fromBackingInt(@intCast(first_signal.load(.acquire))));
    } else if (current) |s| {
        if (s.isCancelled()) deliver(id, .TERM);
    }
    return .{ .slot = found };
}

pub fn untrack(t: Tracked) void {
    const i = t.slot orelse return;
    lock();
    defer unlock();
    slot_ids[i].store(0, .release);
    slot_scopes[i] = null;
}

/// Sends `sig` to a child (and its group when children have their own).
/// Async-signal-safe.
fn deliver(id: usize, sig: posix.SIG) void {
    if (is_windows) {
        // Windows has no signals: any request terminates the process.
        _ = std.os.windows.ntdll.NtTerminateProcess(@ptrFromInt(id), @fromBackingInt(1));
        return;
    }
    if (!has_signals) return;
    // Without own groups a terminal Ctrl-C already reached the child.
    if (!use_groups and sig == .INT) return;
    const pid: posix.pid_t = @intCast(id);
    _ = posix.system.kill(if (use_groups) -pid else pid, sig);
}

fn forwardAll(sig: posix.SIG) void {
    for (&slot_ids) |*slot| {
        const id = slot.load(.acquire);
        if (id != 0) deliver(id, sig);
    }
}

/// Whether children should be spawned in their own process group.
pub fn ownGroups() bool {
    return use_groups;
}

// ------------------------------------------------------------------- signals

fn onSignal(sig: posix.SIG) callconv(.c) void {
    const n = signal_count.fetchAdd(1, .acq_rel);
    if (n == 0) {
        first_signal.store(@intCast(@backingInt(sig)), .release);
        forwardAll(sig);
    } else {
        // A second signal means "now": no more politeness.
        forwardAll(.KILL);
    }
}

/// Installs SIGINT, SIGTERM and SIGHUP handlers that forward the signal to
/// every live child. kevin then waits for them and exits with 128 + signal.
/// A second signal sends SIGKILL. No-op on Windows.
pub fn installSignalHandlers(own_groups: bool) void {
    use_groups = own_groups and !is_windows;
    if (!has_signals) return;
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &act, null);
    posix.sigaction(.TERM, &act, null);
    posix.sigaction(.HUP, &act, null);
}

/// Exit code (128 + signal) when a signal stopped the run.
pub fn signalExitCode() ?u8 {
    const s = first_signal.load(.acquire);
    if (s == 0) return null;
    return @truncate(128 + @as(u32, @intCast(s)));
}

/// Exit status used by children that were not started or were stopped on request.
pub const stopped_code: u8 = 143;

// ------------------------------------------------------------------ temp dir

var temp_dir: ?[]const u8 = null;
var temp_alloc: Allocator = undefined;
var temp_counter: std.atomic.Value(u32) = .init(0);

pub const TempError = error{TempDir} || Allocator.Error;

fn tempBase(env: *const std.process.Environ.Map) []const u8 {
    if (is_windows) {
        return env.get("TEMP") orelse env.get("TMP") orelse ".";
    }
    return env.get("TMPDIR") orelse "/tmp";
}

fn ensureTempDir(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) TempError![]const u8 {
    lock();
    defer unlock();
    if (temp_dir) |d| return d;
    const base = std.mem.trimEnd(u8, tempBase(env), "/\\");
    var attempt: usize = 0;
    while (attempt < 8) : (attempt += 1) {
        var rnd: [8]u8 = undefined;
        io.random(&rnd);
        const path = try std.fmt.allocPrint(gpa, "{s}{c}kevin-{x}", .{ base, std.fs.path.sep, rnd });
        const perm: Io.File.Permissions = if (comptime is_windows) .default_dir else .fromMode(0o700);
        Io.Dir.cwd().createDir(io, path, perm) catch |err| switch (err) {
            error.PathAlreadyExists => {
                gpa.free(path);
                continue;
            },
            else => {
                std.debug.print("kevin: cannot create a temp directory in '{s}': {t}\n", .{ base, err });
                gpa.free(path);
                return error.TempDir;
            },
        };
        temp_dir = path;
        temp_alloc = gpa;
        return path;
    }
    return error.TempDir;
}

/// Writes `code` into a new file of the run's private temp directory (created
/// on first use, mode 0700) and returns its path. `label` becomes part of the
/// file name; `ext` includes the dot.
pub fn writeScript(
    gpa: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    label: []const u8,
    ext: []const u8,
    code: []const u8,
) TempError![]const u8 {
    const dir = try ensureTempDir(gpa, io, env);
    var clean: [32]u8 = undefined;
    var n: usize = 0;
    for (label) |c| {
        if (n == clean.len) break;
        clean[n] = if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') c else '_';
        n += 1;
    }
    const path = try std.fmt.allocPrint(gpa, "{s}{c}{d}-{s}{s}", .{
        dir, std.fs.path.sep, temp_counter.fetchAdd(1, .monotonic), clean[0..n], ext,
    });
    errdefer gpa.free(path);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = code }) catch |err| {
        std.debug.print("kevin: cannot write '{s}': {t}\n", .{ path, err });
        return error.TempDir;
    };
    return path;
}

pub fn removeScript(io: Io, path: []const u8) void {
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// Removes the temp directory and anything left in it. Call once, after
/// every child has exited.
pub fn cleanupTemp(io: Io) void {
    lock();
    defer unlock();
    const d = temp_dir orelse return;
    Io.Dir.cwd().deleteTree(io, d) catch {};
    temp_alloc.free(d);
    temp_dir = null;
}

// -------------------------------------------------------------------- tests

const testing = std.testing;

test "scopes cancel themselves and their descendants" {
    var outer: Scope = .{};
    var inner: Scope = .{ .parent = &outer };
    var sibling: Scope = .{};
    try testing.expect(!inner.isCancelled());
    outer.cancel();
    try testing.expect(outer.isCancelled());
    try testing.expect(inner.isCancelled());
    try testing.expect(!sibling.isCancelled());
    try testing.expect(inner.contains(&outer));
    try testing.expect(!outer.contains(&inner));
}

test "tracked children occupy and free registry slots" {
    const a = track(0x7fff0001);
    const b = track(0x7fff0002);
    try testing.expect(a.slot != null and b.slot != null);
    try testing.expect(a.slot.? != b.slot.?);
    untrack(a);
    const c = track(0x7fff0003);
    try testing.expectEqual(a.slot.?, c.slot.?);
    untrack(b);
    untrack(c);
}

test "scripts are written to a private temp directory and removed" {
    if (is_windows) return error.SkipZigTest;
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("TMPDIR", "/tmp");
    const path = try writeScript(testing.allocator, testing.io, &env, "my task!", ".sh", "echo hi\n");
    defer testing.allocator.free(path);
    try testing.expect(std.mem.indexOf(u8, path, "/kevin-") != null);
    try testing.expect(std.mem.endsWith(u8, path, "-my_task_.sh"));
    var buf: [32]u8 = undefined;
    const got = try Io.Dir.cwd().readFile(testing.io, path, &buf);
    try testing.expectEqualStrings("echo hi\n", got);
    const dir = std.fs.path.dirname(path).?;
    const st = try Io.Dir.cwd().statFile(testing.io, dir, .{});
    try testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    removeScript(testing.io, path);
    cleanupTemp(testing.io);
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(testing.io, dir, .{}));
}
