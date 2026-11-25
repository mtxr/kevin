//! Test plugin for `src/wasm.zig`. Build (output committed as echo.wasm):
//!   zig build-exe src/testdata/echo.zig -target wasm32-freestanding -O ReleaseSmall \
//!       -fno-entry --export=_start -femit-bin=src/testdata/echo.wasm
//! Reads stdin, writes "echo:" and the input upper-cased to stdout and a note
//! to stderr. An empty input calls proc_exit(3).

const Iovec = extern struct { ptr: [*]const u8, len: usize };

extern "wasi_snapshot_preview1" fn fd_read(fd: i32, iovs: *const Iovec, n: usize, nread: *usize) u16;
extern "wasi_snapshot_preview1" fn fd_write(fd: i32, iovs: *const Iovec, n: usize, nwritten: *usize) u16;
extern "wasi_snapshot_preview1" fn proc_exit(code: i32) noreturn;

var buf: [4096]u8 = undefined;

fn write(fd: i32, bytes: []const u8) void {
    var iov: Iovec = .{ .ptr = bytes.ptr, .len = bytes.len };
    var n: usize = 0;
    _ = fd_write(fd, &iov, 1, &n);
}

export fn _start() void {
    var iov: Iovec = .{ .ptr = &buf, .len = buf.len };
    var n: usize = 0;
    _ = fd_read(0, &iov, 1, &n);
    if (n == 0) proc_exit(3);
    for (buf[0..n]) |*b| {
        if (b.* >= 'a' and b.* <= 'z') b.* -= 32;
    }
    write(1, "echo:");
    write(1, buf[0..n]);
    write(2, "note: ok\n");
}
