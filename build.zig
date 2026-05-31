const std = @import("std");
const sokol = @import("sokol");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const with_nim_smoke = b.option(bool, "with-nim-smoke", "Run the Nim ABI smoke test as part of `zig build test`") orelse false;
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_tatfi = b.dependency("tatfi", .{});
    const mod_sokol = dep_sokol.module("sokol");
    const mod_tatfi = dep_tatfi.module("tatfi");
    const mod_okys_shader = try sokol.shdc.createModule(b, "okys_shader", mod_sokol, .{
        .shdc_dep = dep_sokol.builder.dependency("shdc", .{}),
        .input = "src/shaders/smoke.glsl",
        .output = "okys_smoke_shader.zig",
        .slang = .{
            .glsl410 = true,
            .glsl300es = true,
            .hlsl5 = true,
            .metal_macos = true,
            .wgsl = true,
            .spirv_vk = true,
        },
        .reflection = true,
    });
    const mod_okys_path_shader = try sokol.shdc.createModule(b, "okys_path_shader", mod_sokol, .{
        .shdc_dep = dep_sokol.builder.dependency("shdc", .{}),
        .input = "src/shaders/path.glsl",
        .output = "okys_path_shader.zig",
        .slang = .{
            .glsl410 = true,
            .glsl300es = true,
            .hlsl5 = true,
            .metal_macos = true,
            .wgsl = true,
            .spirv_vk = true,
        },
        .reflection = true,
    });
    const mod_okys_blit_shader = try sokol.shdc.createModule(b, "okys_blit_shader", mod_sokol, .{
        .shdc_dep = dep_sokol.builder.dependency("shdc", .{}),
        .input = "src/shaders/blit.glsl",
        .output = "okys_blit_shader.zig",
        .slang = .{
            .glsl410 = true,
            .glsl300es = true,
            .hlsl5 = true,
            .metal_macos = true,
            .wgsl = true,
            .spirv_vk = true,
        },
        .reflection = true,
    });
    const mod_okys_sparse_fine_shader = try sokol.shdc.createModule(b, "okys_sparse_fine_shader", mod_sokol, .{
        .shdc_dep = dep_sokol.builder.dependency("shdc", .{}),
        .input = "src/shaders/sparse_fine.glsl",
        .output = "okys_sparse_fine_shader.zig",
        .slang = .{
            .glsl430 = true,
            .hlsl5 = true,
            .metal_macos = true,
            .wgsl = true,
            .spirv_vk = true,
        },
        .reflection = true,
    });

    const okys_mod = b.createModule(.{
        .root_source_file = b.path("src/okys.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    okys_mod.addImport("sokol", mod_sokol);
    okys_mod.addImport("okys_shader", mod_okys_shader);
    okys_mod.addImport("okys_path_shader", mod_okys_path_shader);
    okys_mod.addImport("okys_blit_shader", mod_okys_blit_shader);
    okys_mod.addImport("okys_sparse_fine_shader", mod_okys_sparse_fine_shader);
    okys_mod.addImport("tatfi", mod_tatfi);

    const tiger_data_mod = b.createModule(.{
        .root_source_file = b.path("tools/tiger_data.zig"),
        .target = target,
        .optimize = optimize,
    });

    const native_demo_mod = b.createModule(.{
        .root_source_file = b.path("demos/native_stencil.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native_demo_mod.addImport("okys", okys_mod);
    native_demo_mod.addImport("sokol", mod_sokol);

    const native_demo = b.addExecutable(.{
        .name = "okys_native_stencil_demo",
        .root_module = native_demo_mod,
    });
    const demo_native_step = b.step("demo-native", "Build the native renderer comparison demo");
    demo_native_step.dependOn(&b.addInstallArtifact(native_demo, .{}).step);
    const run_native_demo = b.addRunArtifact(native_demo);
    const run_demo_native_step = b.step("run-demo-native", "Run the native renderer comparison demo");
    run_demo_native_step.dependOn(&run_native_demo.step);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bench_mod.addImport("okys", okys_mod);
    const bench_options = b.addOptions();
    bench_options.addOption(bool, "tiger_only", false);
    bench_mod.addOptions("bench_options", bench_options);

    const bench = b.addExecutable(.{
        .name = "okys_bench",
        .root_module = bench_mod,
    });
    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run captured-frame CPU benchmarks");
    bench_step.dependOn(&run_bench.step);

    const tiger_bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tiger_bench_mod.addImport("okys", okys_mod);
    const tiger_bench_options = b.addOptions();
    tiger_bench_options.addOption(bool, "tiger_only", true);
    tiger_bench_mod.addOptions("bench_options", tiger_bench_options);

    const tiger_bench = b.addExecutable(.{
        .name = "okys_bench_tiger",
        .root_module = tiger_bench_mod,
    });
    const run_tiger_bench = b.addRunArtifact(tiger_bench);
    const tiger_bench_step = b.step("bench-tiger", "Run Ghostscript Tiger CPU benchmarks");
    tiger_bench_step.dependOn(&run_tiger_bench.step);

    const gpu_bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/gpu_bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    gpu_bench_mod.addImport("okys", okys_mod);
    gpu_bench_mod.addImport("sokol", mod_sokol);
    const gpu_bench_options = b.addOptions();
    gpu_bench_options.addOption(bool, "tiger_only", false);
    gpu_bench_mod.addOptions("bench_options", gpu_bench_options);

    const gpu_bench = b.addExecutable(.{
        .name = "okys_gpu_bench",
        .root_module = gpu_bench_mod,
    });
    const run_gpu_bench = b.addRunArtifact(gpu_bench);
    const gpu_bench_step = b.step("gpu-bench", "Run native sparse GPU frame-loop benchmark");
    gpu_bench_step.dependOn(&run_gpu_bench.step);

    const tiger_gpu_bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/gpu_bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tiger_gpu_bench_mod.addImport("okys", okys_mod);
    tiger_gpu_bench_mod.addImport("sokol", mod_sokol);
    const tiger_gpu_bench_options = b.addOptions();
    tiger_gpu_bench_options.addOption(bool, "tiger_only", true);
    tiger_gpu_bench_mod.addOptions("bench_options", tiger_gpu_bench_options);

    const tiger_gpu_bench = b.addExecutable(.{
        .name = "okys_gpu_bench_tiger",
        .root_module = tiger_gpu_bench_mod,
    });
    const run_tiger_gpu_bench = b.addRunArtifact(tiger_gpu_bench);
    const tiger_gpu_bench_step = b.step("gpu-bench-tiger", "Run Ghostscript Tiger sparse GPU frame-loop benchmark");
    tiger_gpu_bench_step.dependOn(&run_tiger_gpu_bench.step);

    // The C ABI static library. Root is c_api.zig so its export fns are roots.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addIncludePath(b.path("include"));
    lib_mod.addImport("tatfi", mod_tatfi);

    const lib = b.addLibrary(.{
        .name = "okys",
        .linkage = .static,
        .root_module = lib_mod,
    });
    lib.installHeader(b.path("include/okys.h"), "okys.h");
    b.installArtifact(lib);

    // Unit tests live outside production code. tests/unit.zig imports the
    // production modules so their comptime assertions still run.
    const unit_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    unit_mod.addImport("okys", okys_mod);
    unit_mod.addImport("tiger_data", tiger_data_mod);
    const unit_tests = b.addTest(.{ .root_module = unit_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests and the C ABI smoke test");
    test_step.dependOn(&run_unit_tests.step);

    // C ABI smoke test: compile tests/c_abi_smoke.c against the header and link
    // the static library. Proves the header matches the exported symbols.
    const abi_smoke_mod = b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_smoke_mod.addCSourceFile(.{
        .file = b.path("tests/c_abi_smoke.c"),
        .flags = &.{"-std=c11"},
    });
    abi_smoke_mod.addIncludePath(b.path("include"));
    abi_smoke_mod.linkLibrary(lib);

    const abi_smoke = b.addExecutable(.{
        .name = "c_abi_smoke",
        .root_module = abi_smoke_mod,
    });
    const run_abi_smoke = b.addRunArtifact(abi_smoke);
    test_step.dependOn(&run_abi_smoke.step);

    const nim_smoke = b.addSystemCommand(&.{
        "nim",
        "c",
        "-r",
        "--hints:off",
        "--verbosity:0",
        "--nimcache:.zig-cache/nim_abi_smoke",
        "--passC:-Iinclude",
        "--passL:zig-out/lib/libokys.a",
        "--out:zig-out/nim_abi_smoke",
        "tests/nim_abi_smoke.nim",
    });
    nim_smoke.step.dependOn(b.getInstallStep());

    const nim_smoke_step = b.step("nim-smoke", "Run the Nim binding smoke test");
    nim_smoke_step.dependOn(&nim_smoke.step);

    if (with_nim_smoke) {
        test_step.dependOn(&nim_smoke.step);
    }
}
