//! Test plugin for `src/wasm.zig`: reads up to 16 bytes of stdin, adds one to
//! each with a 128-bit vector operation and writes them back. The module uses
//! WebAssembly SIMD, which compilers that embed an engine (Javy) always emit.
//! Build (output committed as simd.wasm):
//!   zig build-exe src/testdata/simd.zig -target wasm32-freestanding -mcpu=generic+simd128 \
//!       -O ReleaseSmall -fno-entry --export=_start -femit-bin=src/testdata/simd.wasm

const Iovec = extern struct { ptr: [*]const u8, len: usize };

extern "wasi_snapshot_preview1" fn fd_read(fd: i32, iovs: *const Iovec, n: usize, nread: *usize) u16;
extern "wasi_snapshot_preview1" fn fd_write(fd: i32, iovs: *const Iovec, n: usize, nwritten: *usize) u16;

export fn _start() void {
    var buf: [16]u8 = @splat(0);
    var iov: Iovec = .{ .ptr = &buf, .len = buf.len };
    var n: usize = 0;
    if (fd_read(0, &iov, 1, &n) != 0) return;

    const v: @Vector(16, u8) = buf;
    const out: [16]u8 = v +% @as(@Vector(16, u8), @splat(1));

    iov = .{ .ptr = &out, .len = n };
    _ = fd_write(1, &iov, 1, &n);
}
