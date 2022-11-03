const std = @import("std");

const pkgs = struct {
    const clap = std.build.Pkg{
        .name = "clap",
        .source = .{ .path = "deps/clap/clap.zig" },
    };
};

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const cmd = b.addSystemCommand(&[_][]const u8{ "git", "submodule", "update", "--init" });

    const exe = b.addExecutable("fzy", "src/main.zig");
    exe.step.dependOn(&cmd.step);
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addIncludePath(".");
    exe.addPackage(pkgs.clap);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    var exe_tests = b.addTest("src/main.zig");
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
