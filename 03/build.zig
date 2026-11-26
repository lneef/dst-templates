const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("kv", .{
        .root_source_file = b.path("src/kv.zig"),
        .target = target,
        .optimize = optimize,
    });

    const module_tests = b.addTest(.{
        .root_module = module,
    });
    const module_tests_run = b.addRunArtifact(module_tests);

    const vsr_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vsr.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const vsr_tests_run = b.addRunArtifact(vsr_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&module_tests_run.step);
    test_step.dependOn(&vsr_tests_run.step);
}
