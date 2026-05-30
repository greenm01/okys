const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const okys_mod = b.createModule(.{
        .root_source_file = b.path("src/okys.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // The C ABI static library. Root is c_api.zig so its export fns are roots.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addIncludePath(b.path("include"));

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
}
