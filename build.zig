const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run all tests");

    const z_core = b.dependency("z_core", .{
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&z_core.builder.top_level_steps.get("test").?.step);

    const z_lib = b.dependency("z_lib", .{
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&z_lib.builder.top_level_steps.get("test").?.step);
}
