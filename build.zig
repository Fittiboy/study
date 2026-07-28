const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "study",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
        }),
    });
    exe.root_module.addImport("study", mod);

    //  ___           _        _ _
    // |_ _|_ __  ___| |_ __ _| | |
    //  | || '_ \/ __| __/ _` | | |
    //  | || | | \__ \ || (_| | | |
    // |___|_| |_|___/\__\__,_|_|_|
    //
    b.installArtifact(exe);

    //  ____
    // |  _ \ _   _ _ __
    // | |_) | | | | '_ \
    // |  _ <| |_| | | | |
    // |_| \_\\__,_|_| |_|
    //
    const run_step = b.step("run", "Run the CLI");
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    run_step.dependOn(&run.step);

    //  _____         _
    // |_   _|__  ___| |_ ___
    //   | |/ _ \/ __| __/ __|
    //   | |  __/\__ \ |_\__ \
    //   |_|\___||___/\__|___/
    //
    const test_step = b.step("test", "Run the tests");
    const test_exe = b.addRunArtifact(b.addTest(.{
        .root_module = mod,
    }));
    test_step.dependOn(&test_exe.step);

    //   ____ _               _       __   _   __
    //  / ___| |__   ___  ___| | __  / /__| |__\ \
    // | |   | '_ \ / _ \/ __| |/ / | |_  / / __| |
    // | |___| | | |  __/ (__|   <  | |/ /| \__ \ |
    //  \____|_| |_|\___|\___|_|\_\ | /___|_|___/ |
    //                               \_\       /_/
    const check = b.step("check", "The check step for zls build-on-save");
    check.dependOn(&exe.step);
}
