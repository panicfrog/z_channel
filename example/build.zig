const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const z_lib_dep = b.dependency("z_lib", .{ .target = target, .optimize = optimize });
    const z_lib_mod = z_lib_dep.module("z_lib");

    const exe = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "z_lib", .module = z_lib_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // `zig build run -- arg1 arg2` 会把 `--` 后的参数透传给程序
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);
}
