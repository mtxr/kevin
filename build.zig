const std = @import("std");

const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Release builds carry no debug info: it was 81% of the Linux binary and
    // added a 3.6 MB .pdb on Windows. Runtime safety checks stay on. Pass
    // -Dstrip=false to keep symbols when debugging a release build.
    const strip = b.option(bool, "strip", "Strip debug info and symbols (default: on outside Debug builds)") orelse (optimize != .debug);

    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);

    const exe = b.addExecutable(.{
        .name = "kevin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{.{ .name = "build_options", .module = options.createModule() }},
        }),
    });
    addWamr(b, exe.root_module, target, optimize);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run kevin");
    run_step.dependOn(&run_cmd.step);

    // main.zig imports every module in a `test` block, so one test binary covers all.
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

/// Sources of the vendored WebAssembly Micro Runtime (`vendor/wamr`): the fast
/// interpreter with the full (validating) loader. Neither AOT, JIT, WAMR's own
/// WASI nor its libc are built: the host functions a plugin can call are
/// kevin's, see `src/wasm.zig`.
const wamr_sources = [_][]const u8{
    "core/iwasm/interpreter/wasm_loader.c",
    "core/iwasm/interpreter/wasm_runtime.c",
    "core/iwasm/interpreter/wasm_interp_fast.c",
    "core/iwasm/common/wasm_application.c",
    "core/iwasm/common/wasm_blocking_op.c",
    "core/iwasm/common/wasm_c_api.c",
    "core/iwasm/common/wasm_exec_env.c",
    "core/iwasm/common/wasm_loader_common.c",
    "core/iwasm/common/wasm_memory.c",
    "core/iwasm/common/wasm_native.c",
    "core/iwasm/common/wasm_runtime_common.c",
    "core/shared/utils/bh_assert.c",
    "core/shared/utils/bh_bitmap.c",
    "core/shared/utils/bh_common.c",
    "core/shared/utils/bh_hashmap.c",
    "core/shared/utils/bh_leb128.c",
    "core/shared/utils/bh_list.c",
    "core/shared/utils/bh_log.c",
    "core/shared/utils/bh_queue.c",
    "core/shared/utils/bh_vector.c",
    "core/shared/utils/runtime_timer.c",
    "core/shared/mem-alloc/mem_alloc.c",
    "core/shared/mem-alloc/ems/ems_alloc.c",
    "core/shared/mem-alloc/ems/ems_gc.c",
    "core/shared/mem-alloc/ems/ems_hmu.c",
    "core/shared/mem-alloc/ems/ems_kfc.c",
    "core/shared/platform/common/posix/posix_blocking_op.c",
    "core/shared/platform/common/posix/posix_malloc.c",
    "core/shared/platform/common/posix/posix_memmap.c",
    "core/shared/platform/common/posix/posix_sleep.c",
    "core/shared/platform/common/posix/posix_thread.c",
    "core/shared/platform/common/posix/posix_time.c",
};

/// Whether the WebAssembly runtime is available for `target` (POSIX only for now).
pub fn wasmSupported(target: std.Build.ResolvedTarget) bool {
    return switch (target.result.os.tag) {
        .macos, .linux => true,
        else => false,
    };
}

fn addWamr(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const supported = wasmSupported(target);
    const opts = b.addOptions();
    opts.addOption(bool, "wasm", supported);
    module.addOptions("wasm_options", opts);
    if (!supported) return;

    const os = target.result.os.tag;
    const arch_macro = switch (target.result.cpu.arch) {
        .aarch64 => "BUILD_TARGET_AARCH64",
        .x86_64 => "BUILD_TARGET_X86_64",
        else => @panic("wasm runtime: unsupported CPU architecture"),
    };
    const platform = if (os == .macos) "darwin" else "linux";

    const flags = [_][]const u8{
        "-std=gnu11",
        "-w", // vendored code: warnings are upstream's business
        "-fno-sanitize=undefined",
        "-DWASM_ENABLE_INTERP=1",
        "-DWASM_ENABLE_FAST_INTERP=1",
        "-DWASM_ENABLE_MINI_LOADER=0", // keep the full validating loader
        "-DWASM_ENABLE_AOT=0",
        "-DWASM_ENABLE_JIT=0",
        "-DWASM_ENABLE_FAST_JIT=0",
        "-DWASM_ENABLE_LIBC_BUILTIN=0",
        "-DWASM_ENABLE_LIBC_WASI=0",
        "-DWASM_ENABLE_THREAD_MGR=0",
        "-DWASM_ENABLE_SHARED_MEMORY=0",
        "-DWASM_ENABLE_MULTI_MODULE=0",
        // memory.copy/fill: emitted by default by Zig, Rust and Go for wasm32.
        "-DWASM_ENABLE_BULK_MEMORY=1",
        "-DWASM_ENABLE_BULK_MEMORY_OPT=1",
        "-DWASM_ENABLE_REF_TYPES=1",
        "-DWASM_ENABLE_INSTRUCTION_METERING=1",
        // WebAssembly SIMD, executed by the fast interpreter through simde
        // (vendor/simde). Compilers that embed an engine, such as Javy for
        // JavaScript, emit SIMD, so without it their plugins cannot load.
        "-DWASM_ENABLE_SIMD=1",
        "-DWASM_ENABLE_SIMDE=1",
        // Software bounds checks: no SIGSEGV handler (kevin owns signals, see
        // proc.zig) and no multi-GiB address-space reservation per memory.
        "-DWASM_DISABLE_HW_BOUND_CHECK=1",
        "-DBH_MALLOC=wasm_runtime_malloc",
        "-DBH_FREE=wasm_runtime_free",
    };
    var all_flags: std.ArrayList([]const u8) = .empty;
    all_flags.appendSlice(b.allocator, &flags) catch @panic("OOM");
    all_flags.append(b.allocator, b.fmt("-D{s}", .{arch_macro})) catch @panic("OOM");

    var sources: std.ArrayList([]const u8) = .empty;
    sources.appendSlice(b.allocator, &wamr_sources) catch @panic("OOM");
    if (os == .linux) {
        all_flags.appendSlice(b.allocator, &.{ "-DWASM_HAVE_MREMAP=1", "-D_GNU_SOURCE" }) catch @panic("OOM");
    } else {
        // Without mremap(2) (macOS) WAMR ships its own.
        all_flags.append(b.allocator, "-DWASM_HAVE_MREMAP=0") catch @panic("OOM");
        sources.append(b.allocator, "core/shared/platform/common/memory/mremap.c") catch @panic("OOM");
    }
    sources.append(b.allocator, b.fmt("core/shared/platform/{s}/platform_init.c", .{platform})) catch @panic("OOM");

    module.link_libc = true;
    module.addCSourceFiles(.{ .root = b.path("vendor/wamr"), .files = sources.items, .flags = all_flags.items });
    // The calling-convention trampoline: invokeNative_general.c only works on
    // 32-bit targets (it passes every argument as uint32), so use the assembly,
    // and the variant that knows about v128 (the plain one crashes once SIMD is on).
    const trampoline = switch (target.result.cpu.arch) {
        .aarch64 => "core/iwasm/common/arch/invokeNative_aarch64_simd.s",
        else => "core/iwasm/common/arch/invokeNative_em64_simd.s",
    };
    module.addCSourceFiles(.{
        .root = b.path("vendor/wamr"),
        .files = &.{trampoline},
        .flags = &.{if (os == .macos) "-DBH_PLATFORM_DARWIN" else "-DBH_PLATFORM_LINUX"},
        .language = .assembly_with_preprocessor,
    });
    const includes = [_][]const u8{
        "vendor/wamr/core",
        "vendor/wamr/core/iwasm/include",
        "vendor/wamr/core/iwasm/interpreter",
        "vendor/wamr/core/iwasm/common",
        "vendor/wamr/core/shared/utils",
        "vendor/wamr/core/shared/mem-alloc",
        "vendor/wamr/core/shared/mem-alloc/ems",
    };
    for (includes) |inc| module.addIncludePath(b.path(inc));
    module.addIncludePath(b.path("vendor/simde"));
    module.addIncludePath(b.path(b.fmt("vendor/wamr/core/shared/platform/{s}", .{platform})));
    module.addIncludePath(b.path("vendor/wamr/core/shared/platform/include"));
    if (os == .macos) module.addIncludePath(b.path("build/shims"));

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("vendor/wamr/wamr.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(b.path("vendor/wamr/core/iwasm/include"));
    module.addImport("wamr", translate.createModule());
}
