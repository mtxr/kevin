//! Test plugin for `src/wasm.zig`: writes each argument followed by a newline,
//! then `env=<number of environment variables>`. Build (output committed as
//! args.wasm):
//!   zig build-exe src/testdata/args.zig -target wasm32-freestanding -O ReleaseSmall \
//!       -fno-entry --export=_start -femit-bin=src/testdata/args.wasm

const Iovec = extern struct { ptr: [*]const u8, len: usize };

extern "wasi_snapshot_preview1" fn args_sizes_get(argc: *usize, size: *usize) u16;
extern "wasi_snapshot_preview1" fn args_get(argv: [*]usize, buf: [*]u8) u16;
extern "wasi_snapshot_preview1" fn environ_sizes_get(count: *usize, size: *usize) u16;
extern "wasi_snapshot_preview1" fn fd_write(fd: i32, iovs: *const Iovec, n: usize, nwritten: *usize) u16;

var argv: [32]usize = undefined;
var buf: [4096]u8 = undefined;

fn write(bytes: []const u8) void {
    var iov: Iovec = .{ .ptr = bytes.ptr, .len = bytes.len };
    var n: usize = 0;
    _ = fd_write(1, &iov, 1, &n);
}

export fn _start() void {
    var argc: usize = 0;
    var size: usize = 0;
    _ = args_sizes_get(&argc, &size);
    if (argc > argv.len or size > buf.len) return;
    _ = args_get(&argv, &buf);
    for (argv[0..argc]) |ptr| {
        const start: [*]const u8 = @ptrFromInt(ptr);
        var len: usize = 0;
        while (start[len] != 0) len += 1;
        write(start[0..len]);
        write("\n");
    }
    var count: usize = 0;
    _ = environ_sizes_get(&count, &size);
    write("env=");
    write(&[_]u8{@intCast('0' + count)});
    write("\n");
}
