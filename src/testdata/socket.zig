//! Test plugin for `src/wasm.zig`: calls a WASI function the sandbox does not
//! provide (a socket). Build (output committed as socket.wasm):
//!   zig build-exe src/testdata/socket.zig -target wasm32-freestanding -O ReleaseSmall \
//!       -fno-entry --export=_start -femit-bin=src/testdata/socket.wasm

extern "wasi_snapshot_preview1" fn sock_accept(fd: i32, flags: i32, out: *i32) u16;

export fn _start() void {
    var accepted: i32 = 0;
    _ = sock_accept(3, 0, &accepted);
}
