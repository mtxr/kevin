//! Sandboxed WebAssembly runner for converter plugins.
//!
//! A plugin is a WASI "command": it reads its input from stdin, writes the
//! result to stdout, notes to stderr, and reports failure with a non-zero
//! exit code. The host functions it can import are all defined here, and
//! none of them touches the outside world:
//!
//!   - stdin/stdout/stderr are in-memory buffers (fd 0, 1, 2 only);
//!   - the arguments are exactly the ones the host passes (kevin passes
//!     `--path <input file>`); the environment is empty;
//!   - there is no filesystem (no preopened directories), network or process
//!     API: an import that is not listed below is left unlinked, and the
//!     plugin traps the moment it calls it;
//!   - the clock is frozen and `random_get` is a fixed-seed generator, so a
//!     conversion is reproducible;
//!   - `proc_exit` ends the plugin, never kevin.
//!
//! Memory (one pool for the module, its stack and its linear memory), executed
//! instructions and output size are capped. The runtime is initialised and
//! destroyed per `run`, so nothing leaks between plugins.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wasm_options = @import("wasm_options");

pub const supported = wasm_options.wasm;

const c = if (supported) @import("wamr") else struct {};

pub const Limits = struct {
    /// Bytes available to the runtime for everything the plugin loads and allocates.
    memory: u32 = 64 * 1024 * 1024,
    /// WebAssembly instructions the plugin may execute (`i32` in the runtime).
    instructions: i32 = 1_000_000_000,
    /// Bytes accepted on stdout and on stderr, each.
    output: usize = 16 * 1024 * 1024,
    /// Stack of the plugin, in bytes.
    stack: u32 = 256 * 1024,
};

pub const Output = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
};

pub const Error = error{
    /// The runtime or the module could not be set up; see `Diagnostic`.
    Load,
    /// The module trapped, ran out of instructions or broke a limit.
    Trap,
    Unsupported,
} || Allocator.Error;

/// Human readable reason for the last `Error`; owned by the arena given to `run`.
pub const Diagnostic = struct {
    message: []const u8 = "",
    /// What the plugin wrote on stderr before it failed. Languages that cannot
    /// exit with a code (a JavaScript plugin throwing) explain themselves here.
    stderr: []const u8 = "",
};

const Errno = enum(i32) {
    success = 0,
    badf = 8,
    fault = 21,
    inval = 28,
    nosys = 52,
    spipe = 70,
};

const Ctx = struct {
    arena: Allocator,
    limits: Limits,
    stdin: []const u8,
    args: []const []const u8,
    stdin_pos: usize = 0,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    exit_code: ?u8 = null,
    over_limit: bool = false,
    rng: u64 = 0x9E3779B97F4A7C15,
};

/// Runs `wasm` (a binary module with a `_start` export) feeding it `stdin`;
/// `args` is its argv, program name first.
pub fn run(
    arena: Allocator,
    wasm: []const u8,
    stdin: []const u8,
    args: []const []const u8,
    limits: Limits,
    diag: *Diagnostic,
) Error!Output {
    if (!supported) {
        diag.message = "this build of kevin has no WebAssembly runtime";
        return error.Unsupported;
    }

    var ctx: Ctx = .{ .arena = arena, .limits = limits, .stdin = stdin, .args = args };

    const pool = try arena.alignedAlloc(u8, .@"16", limits.memory);
    var init: c.RuntimeInitArgs = std.mem.zeroes(c.RuntimeInitArgs);
    init.mem_alloc_type = c.Alloc_With_Pool;
    init.mem_alloc_option.pool.heap_buf = pool.ptr;
    init.mem_alloc_option.pool.heap_size = limits.memory;
    init.native_module_name = "wasi_snapshot_preview1";
    init.native_symbols = &natives;
    init.n_native_symbols = natives.len;
    if (!c.wasm_runtime_full_init(&init)) {
        diag.message = "cannot initialise the WebAssembly runtime";
        return error.Load;
    }
    defer c.wasm_runtime_destroy();
    // The runtime logs on its own to stderr; failures reach the caller as a
    // `Diagnostic`, so keep that channel for real errors.
    c.wasm_runtime_set_log_level(c.WASM_LOG_LEVEL_ERROR);

    var err_buf: [256]u8 = undefined;
    // The loader may rewrite the buffer in place, so give it a private copy.
    const code = try arena.dupe(u8, wasm);
    const module = c.wasm_runtime_load(code.ptr, @intCast(code.len), &err_buf, err_buf.len) orelse
        return fail(arena, diag, "invalid module", &err_buf, error.Load);
    defer c.wasm_runtime_unload(module);

    const inst = c.wasm_runtime_instantiate(module, limits.stack, 0, &err_buf, err_buf.len) orelse
        return fail(arena, diag, "cannot instantiate", &err_buf, error.Load);
    defer c.wasm_runtime_deinstantiate(inst);

    const env = c.wasm_runtime_create_exec_env(inst, limits.stack) orelse {
        diag.message = "cannot create the execution environment";
        return error.Load;
    };
    defer c.wasm_runtime_destroy_exec_env(env);
    c.wasm_runtime_set_user_data(env, &ctx);
    c.wasm_runtime_set_instruction_count_limit(env, limits.instructions);

    const start = c.wasm_runtime_lookup_function(inst, "_start") orelse {
        diag.message = "the module does not export '_start'";
        return error.Load;
    };

    const ok = c.wasm_runtime_call_wasm(env, start, 0, null);
    if (!ok and ctx.exit_code == null) {
        const exc: [*c]const u8 = c.wasm_runtime_get_exception(inst);
        const reason = if (exc != null) std.mem.span(exc) else "trap";
        diag.message = try arena.dupe(u8, if (ctx.over_limit) "the plugin produced too much output" else reason);
        diag.stderr = ctx.stderr.items;
        return error.Trap;
    }
    return .{
        .stdout = ctx.stdout.items,
        .stderr = ctx.stderr.items,
        .exit_code = ctx.exit_code orelse 0,
    };
}

fn fail(arena: Allocator, diag: *Diagnostic, what: []const u8, buf: []const u8, err: Error) Error {
    const detail = std.mem.sliceTo(buf, 0);
    diag.message = std.fmt.allocPrint(arena, "{s}: {s}", .{ what, detail }) catch what;
    return err;
}

// ------------------------------------------------------------- host functions

fn ctxOf(env: c.wasm_exec_env_t) *Ctx {
    return @ptrCast(@alignCast(c.wasm_runtime_get_user_data(env).?));
}

/// Native view of `len` bytes of the plugin's memory at `offset`, or null when
/// the range is not entirely inside it.
fn view(env: c.wasm_exec_env_t, offset: u32, len: u32) ?[]u8 {
    const inst = c.wasm_runtime_get_module_inst(env);
    if (!c.wasm_runtime_validate_app_addr(inst, offset, len)) return null;
    const p: [*]u8 = @ptrCast(c.wasm_runtime_addr_app_to_native(inst, offset) orelse return null);
    return p[0..len];
}

fn putU32(env: c.wasm_exec_env_t, offset: u32, value: u32) bool {
    const dst = view(env, offset, 4) orelse return false;
    std.mem.writeInt(u32, dst[0..4], value, .little);
    return true;
}

fn putU64(env: c.wasm_exec_env_t, offset: u32, value: u64) bool {
    const dst = view(env, offset, 8) orelse return false;
    std.mem.writeInt(u64, dst[0..8], value, .little);
    return true;
}

fn ret(e: Errno) i32 {
    return @backingInt(e);
}

fn isStdio(fd: i32) bool {
    return fd >= 0 and fd <= 2;
}

fn fdRead(env: c.wasm_exec_env_t, fd: i32, iovs: u32, iovs_len: u32, nread_ptr: u32) callconv(.c) i32 {
    const ctx = ctxOf(env);
    if (fd != 0) return ret(.badf);
    const list = view(env, iovs, std.math.mul(u32, iovs_len, 8) catch return ret(.fault)) orelse return ret(.fault);
    var total: u32 = 0;
    var i: u32 = 0;
    while (i < iovs_len) : (i += 1) {
        const ptr = std.mem.readInt(u32, list[i * 8 ..][0..4], .little);
        const len = std.mem.readInt(u32, list[i * 8 ..][4..8], .little);
        const dst = view(env, ptr, len) orelse return ret(.fault);
        const left = ctx.stdin.len - ctx.stdin_pos;
        const n = @min(left, dst.len);
        @memcpy(dst[0..n], ctx.stdin[ctx.stdin_pos..][0..n]);
        ctx.stdin_pos += n;
        total += @intCast(n);
        if (n < dst.len) break;
    }
    if (!putU32(env, nread_ptr, total)) return ret(.fault);
    return ret(.success);
}

fn fdWrite(env: c.wasm_exec_env_t, fd: i32, iovs: u32, iovs_len: u32, nwritten_ptr: u32) callconv(.c) i32 {
    const ctx = ctxOf(env);
    const sink: *std.ArrayList(u8) = switch (fd) {
        1 => &ctx.stdout,
        2 => &ctx.stderr,
        else => return ret(.badf),
    };
    const list = view(env, iovs, std.math.mul(u32, iovs_len, 8) catch return ret(.fault)) orelse return ret(.fault);
    var total: u32 = 0;
    var i: u32 = 0;
    while (i < iovs_len) : (i += 1) {
        const ptr = std.mem.readInt(u32, list[i * 8 ..][0..4], .little);
        const len = std.mem.readInt(u32, list[i * 8 ..][4..8], .little);
        const src = view(env, ptr, len) orelse return ret(.fault);
        if (sink.items.len + src.len > ctx.limits.output) {
            ctx.over_limit = true;
            c.wasm_runtime_set_exception(c.wasm_runtime_get_module_inst(env), "output limit exceeded");
            return ret(.inval);
        }
        sink.appendSlice(ctx.arena, src) catch return ret(.inval);
        total += @intCast(src.len);
    }
    if (!putU32(env, nwritten_ptr, total)) return ret(.fault);
    return ret(.success);
}

fn procExit(env: c.wasm_exec_env_t, code: i32) callconv(.c) void {
    const ctx = ctxOf(env);
    ctx.exit_code = @truncate(@as(u32, @bitCast(code)));
    // Unwinds the plugin; `run` recognises it by `exit_code`.
    c.wasm_runtime_set_exception(c.wasm_runtime_get_module_inst(env), "proc_exit");
}

fn fdClose(_: c.wasm_exec_env_t, fd: i32) callconv(.c) i32 {
    return ret(if (isStdio(fd)) .success else .badf);
}

fn fdSeek(_: c.wasm_exec_env_t, fd: i32, _: i64, _: i32, _: u32) callconv(.c) i32 {
    return ret(if (isStdio(fd)) .spipe else .badf);
}

/// No preopened directories: this is the end-of-list answer.
fn fdPrestatGet(_: c.wasm_exec_env_t, _: i32, _: u32) callconv(.c) i32 {
    return ret(.badf);
}

fn fdPrestatDirName(_: c.wasm_exec_env_t, _: i32, _: u32, _: u32) callconv(.c) i32 {
    return ret(.badf);
}

fn fdFdstatGet(env: c.wasm_exec_env_t, fd: i32, buf: u32) callconv(.c) i32 {
    if (!isStdio(fd)) return ret(.badf);
    const dst = view(env, buf, 24) orelse return ret(.fault);
    @memset(dst, 0);
    dst[0] = 2; // character device
    return ret(.success);
}

fn argsSizesGet(env: c.wasm_exec_env_t, argc_ptr: u32, size_ptr: u32) callconv(.c) i32 {
    const ctx = ctxOf(env);
    var total: u32 = 0;
    for (ctx.args) |a| total = std.math.add(u32, total, @intCast(a.len + 1)) catch return ret(.inval);
    if (!putU32(env, argc_ptr, @intCast(ctx.args.len)) or !putU32(env, size_ptr, total)) return ret(.fault);
    return ret(.success);
}

fn argsGet(env: c.wasm_exec_env_t, argv_ptr: u32, buf_ptr: u32) callconv(.c) i32 {
    const ctx = ctxOf(env);
    var off: u32 = 0;
    for (ctx.args, 0..) |a, i| {
        const len: u32 = @intCast(a.len + 1);
        const at = std.math.add(u32, buf_ptr, off) catch return ret(.fault);
        const dst = view(env, at, len) orelse return ret(.fault);
        @memcpy(dst[0..a.len], a);
        dst[a.len] = 0;
        const slot = std.math.add(u32, argv_ptr, @intCast(i * 4)) catch return ret(.fault);
        if (!putU32(env, slot, at)) return ret(.fault);
        off += len;
    }
    return ret(.success);
}

/// The environment is always empty.
fn environSizesGet(env: c.wasm_exec_env_t, count_ptr: u32, size_ptr: u32) callconv(.c) i32 {
    if (!putU32(env, count_ptr, 0) or !putU32(env, size_ptr, 0)) return ret(.fault);
    return ret(.success);
}

fn environGet(_: c.wasm_exec_env_t, _: u32, _: u32) callconv(.c) i32 {
    return ret(.success);
}

fn clockTimeGet(env: c.wasm_exec_env_t, _: i32, _: i64, time_ptr: u32) callconv(.c) i32 {
    if (!putU64(env, time_ptr, 0)) return ret(.fault);
    return ret(.success);
}

fn randomGet(env: c.wasm_exec_env_t, buf: u32, len: u32) callconv(.c) i32 {
    const ctx = ctxOf(env);
    const dst = view(env, buf, len) orelse return ret(.fault);
    for (dst) |*b| {
        // xorshift64*: deterministic on purpose.
        ctx.rng ^= ctx.rng >> 12;
        ctx.rng ^= ctx.rng << 25;
        ctx.rng ^= ctx.rng >> 27;
        b.* = @truncate((ctx.rng *% 0x2545F4914F6CDD1D) >> 56);
    }
    return ret(.success);
}

fn sym(comptime name: [:0]const u8, comptime f: anytype, comptime signature: [:0]const u8) if (supported) c.NativeSymbol else void {
    return .{ .symbol = name.ptr, .func_ptr = @ptrCast(@constCast(&f)), .signature = signature.ptr, .attachment = null };
}

var natives = if (supported) [_]c.NativeSymbol{
    sym("fd_read", fdRead, "(iiii)i"),
    sym("fd_write", fdWrite, "(iiii)i"),
    sym("fd_close", fdClose, "(i)i"),
    sym("fd_seek", fdSeek, "(iIii)i"),
    sym("fd_fdstat_get", fdFdstatGet, "(ii)i"),
    sym("fd_prestat_get", fdPrestatGet, "(ii)i"),
    sym("fd_prestat_dir_name", fdPrestatDirName, "(iii)i"),
    sym("args_sizes_get", argsSizesGet, "(ii)i"),
    sym("args_get", argsGet, "(ii)i"),
    sym("environ_sizes_get", environSizesGet, "(ii)i"),
    sym("environ_get", environGet, "(ii)i"),
    sym("clock_time_get", clockTimeGet, "(iIi)i"),
    sym("random_get", randomGet, "(ii)i"),
    sym("proc_exit", procExit, "(i)"),
} else .{};

// ---------------------------------------------------------------------- tests

const testing = std.testing;

/// `src/testdata/echo.zig` built for wasm32-freestanding: reads stdin, writes
/// "echo:" and the input upper-cased to stdout, a note to stderr, exits 0; an
/// empty input makes it call `proc_exit(3)`.
const echo_wasm = @embedFile("testdata/echo.wasm");

test "runs a plugin: stdin in, stdout and stderr out" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const out = try run(arena_state.allocator(), echo_wasm, "hello kevin\n", &.{"echo"}, .{}, &diag);
    try testing.expectEqualStrings("echo:HELLO KEVIN\n", out.stdout);
    try testing.expectEqualStrings("note: ok\n", out.stderr);
    try testing.expectEqual(@as(u8, 0), out.exit_code);
}

test "proc_exit ends the plugin and reports its code, not kevin" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const out = try run(arena_state.allocator(), echo_wasm, "", &.{"echo"}, .{}, &diag);
    try testing.expectEqual(@as(u8, 3), out.exit_code);
}

test "output beyond the limit stops the plugin" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.Trap, run(arena_state.allocator(), echo_wasm, "abcdefghij", &.{"echo"}, .{ .output = 4 }, &diag));
    try testing.expectEqualStrings("the plugin produced too much output", diag.message);
}

test "the instruction budget stops a runaway plugin" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const input: [1000]u8 = @splat('x');
    try testing.expectError(error.Trap, run(arena_state.allocator(), echo_wasm, &input, &.{"echo"}, .{ .instructions = 50 }, &diag));
}

test "garbage is not a module" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.Load, run(arena_state.allocator(), "not wasm at all", "", &.{"x"}, .{}, &diag));
    try testing.expect(diag.message.len > 0);
}

test "a WASI function that is not provided traps when called" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.Trap, run(arena_state.allocator(), @embedFile("testdata/socket.wasm"), "", &.{"socket"}, .{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "sock_accept") != null);
}

/// `src/testdata/args.zig`: writes each argument followed by a newline.
const args_wasm = @embedFile("testdata/args.wasm");

test "the plugin sees exactly the arguments it was given, and an empty environment" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const out = try run(arena_state.allocator(), args_wasm, "", &.{ "plugin", "--path", "pkg/package.json" }, .{}, &diag);
    try testing.expectEqualStrings("plugin\n--path\npkg/package.json\nenv=0\n", out.stdout);
}

test "a module that uses SIMD loads and runs" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    // `src/testdata/simd.zig` adds one to each byte with a 128-bit vector.
    const out = try run(arena_state.allocator(), @embedFile("testdata/simd.wasm"), "HAL", &.{"simd"}, .{}, &diag);
    try testing.expectEqualStrings("IBM", out.stdout);
}

test "a trap keeps what the plugin said on stderr" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.Trap, run(arena_state.allocator(), @embedFile("testdata/trap.wasm"), "", &.{"trap"}, .{}, &diag));
    try testing.expectEqualStrings("no usable script\n", diag.stderr);
}
