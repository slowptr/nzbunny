const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("nzigbunny", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = false,
    });
    module.linkSystemLibrary("sqlite3", .{});
    module.linkSystemLibrary("archive", .{});

    const exe = b.addExecutable(.{
        .name = "nzigbunny",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nzigbunny", .module = module }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run nzigbunny").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = module });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const integration = b.addSystemCommand(&.{"python3"});
    integration.addFileArg(b.path("tests/integration.py"));
    integration.addArtifactArg(exe);
    test_step.dependOn(&integration.step);
}
