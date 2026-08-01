const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const skip_integration = b.option(bool, "skip_integration", "Skip Python integration test") orelse false;

    const module = b.addModule("nzbunny", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = false,
    });
    module.linkSystemLibrary("sqlite3", .{});
    module.linkSystemLibrary("archive", .{});
    module.linkSystemLibrary("xml2", .{ .use_pkg_config = .yes });
    module.addSystemIncludePath(.{ .cwd_relative = "/usr/include/libxml2" });

    const exe = b.addExecutable(.{
        .name = "nzbunny",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nzbunny", .module = module }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run nzbunny").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = module });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    if (!skip_integration) {
        const integration = b.addSystemCommand(&.{"python3"});
        integration.addFileArg(b.path("tests/integration.py"));
        integration.addArtifactArg(exe);
        test_step.dependOn(&integration.step);
    }
}
