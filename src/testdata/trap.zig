//! Test plugin for `src/wasm.zig`: explains itself on stderr, then traps. This
//! is how a JavaScript plugin (Javy) fails, since it cannot exit with a code.
//! Build (output committed as trap.wasm):
//!   zig build-exe src/testdata/trap.zig -target wasm32-freestanding -O ReleaseSmall \
//!       -fno-entry --export=_start -femit-bin=src/testdata/trap.wasm

const Iovec = extern struct { ptr: [*]const u8, len: usize };

extern "wasi_snapshot_preview1" fn fd_write(fd: i32, iovs: *const Iovec, n: usize, nwritten: *usize) u16;

export fn _start() void {
    const msg = "no usable script\n";
    var iov: Iovec = .{ .ptr = msg, .len = msg.len };
    var n: usize = 0;
    _ = fd_write(2, &iov, 1, &n);
    @trap();
}
