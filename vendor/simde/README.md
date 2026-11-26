# simde (subset)

SIMD Everywhere 0.8.2, https://github.com/simd-everywhere/simde (tag v0.8.2,
commit 71fd833). MIT, see `COPYING`.

Only the headers that `simde/wasm/simd128.h` includes are kept (12 files); the
rest of the project (x86 and Arm intrinsics) is not needed. They are unchanged.
WAMR's fast interpreter uses them to execute WebAssembly SIMD instructions
(`WASM_ENABLE_SIMDE`, see `build.zig`).

To update: take the same set of files from a new release and rebuild.
