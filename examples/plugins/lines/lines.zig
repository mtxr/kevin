//! Example converter plugin: turns a list of `name: command` lines into kevin
//! tasks. Blank lines and lines starting with `#` are ignored; a line without
//! a colon is reported on stderr (a note) and skipped. No task at all exits 1.
//!
//! Build (see PLUGINS.md):
//!   zig build-exe lines.zig -target wasm32-freestanding -O ReleaseSmall \
//!       -fno-entry --export=_start -femit-bin=lines.wasm

const Iovec = extern struct { ptr: [*]const u8, len: usize };

extern "wasi_snapshot_preview1" fn fd_read(fd: i32, iovs: *const Iovec, n: usize, nread: *usize) u16;
extern "wasi_snapshot_preview1" fn fd_write(fd: i32, iovs: *const Iovec, n: usize, nwritten: *usize) u16;
extern "wasi_snapshot_preview1" fn proc_exit(code: i32) noreturn;

var input: [64 * 1024]u8 = undefined;
var output: [128 * 1024]u8 = undefined;
var out_len: usize = 0;

fn emit(bytes: []const u8) void {
    if (out_len + bytes.len > output.len) {
        note("output too large\n");
        proc_exit(1);
    }
    @memcpy(output[out_len..][0..bytes.len], bytes);
    out_len += bytes.len;
}

fn note(bytes: []const u8) void {
    var iov: Iovec = .{ .ptr = bytes.ptr, .len = bytes.len };
    var n: usize = 0;
    _ = fd_write(2, &iov, 1, &n);
}

fn trim(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\t' or s[a] == '\r')) a += 1;
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t' or s[b - 1] == '\r')) b -= 1;
    return s[a..b];
}

export fn _start() void {
    // Read all of stdin.
    var len: usize = 0;
    while (len < input.len) {
        var iov: Iovec = .{ .ptr = input[len..].ptr, .len = input.len - len };
        var n: usize = 0;
        if (fd_read(0, &iov, 1, &n) != 0 or n == 0) break;
        len += n;
    }

    emit("# Tasks\n");
    var tasks: usize = 0;
    var lineno: usize = 0;
    var rest: []const u8 = input[0..len];
    while (rest.len > 0) {
        var end: usize = 0;
        while (end < rest.len and rest[end] != '\n') end += 1;
        const line = trim(rest[0..end]);
        rest = if (end < rest.len) rest[end + 1 ..] else rest[end..];
        lineno += 1;
        if (line.len == 0 or line[0] == '#') continue;

        var colon: usize = 0;
        while (colon < line.len and line[colon] != ':') colon += 1;
        const name = trim(line[0..colon]);
        const command = if (colon < line.len) trim(line[colon + 1 ..]) else "";
        if (name.len == 0 or command.len == 0) {
            note("skipped a line that is not 'name: command'\n");
            continue;
        }
        emit("\n## > ");
        emit(name);
        emit("\n\n```sh\n");
        emit(command);
        emit("\n```\n");
        tasks += 1;
    }
    if (tasks == 0) {
        note("no 'name: command' line found\n");
        proc_exit(1);
    }

    var iov: Iovec = .{ .ptr = &output, .len = out_len };
    var n: usize = 0;
    _ = fd_write(1, &iov, 1, &n);
}
