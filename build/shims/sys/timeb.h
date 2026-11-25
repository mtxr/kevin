// WAMR's darwin platform header includes <sys/timeb.h> but never uses it, and
// the libc headers Zig bundles for macOS lack it. An empty stand-in keeps the
// vendored sources unmodified.
