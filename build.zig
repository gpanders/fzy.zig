const std = @import("std");

const pkgs = struct {
    const clap = .{
        .source_file = .{ .path = "deps/clap/clap.zig" },
    };

    const config = .{
        .source_file = .{ .path = "config.zig" },
    };
};

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cmd = b.addSystemCommand(&[_][]const u8{ "git", "submodule", "update", "--init" });

    const exe = b.addExecutable(.{
        .name = "fzy",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.step.dependOn(&cmd.step);
    exe.addAnonymousModule("clap", pkgs.clap);
    exe.addAnonymousModule("config", pkgs.config);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    var exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
