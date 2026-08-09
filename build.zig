const std = @import("std");

const exe_name = "study";
const release_targets: []const std.Target.Query = &.{
    // macOS
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },

    // Linux
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },

    // Windows
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });

    const root_source_file_exe: std.Build.LazyPath = b.path("src/main.zig");
    try release(b, root_source_file_exe, root_mod);

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = root_source_file_exe,
        }),
    });
    exe.root_module.addImport("study", root_mod);

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
        .root_module = root_mod,
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

pub fn release(
    b: *std.Build,
    root_exe: std.Build.LazyPath,
    root_mod: *std.Build.Module,
) !void {
    const release_step = b.step(
        "release",
        "Build release binaries for preconfigured targets",
    );

    for (release_targets) |target| {
        const exe = b.addExecutable(.{
            .name = exe_name,
            .root_module = b.createModule(.{
                .root_source_file = root_exe,
                .target = b.resolveTargetQuery(target),
                .optimize = .ReleaseSafe,
                .imports = &.{
                    .{ .name = "study", .module = root_mod },
                },
            }),
        });

        const target_output = b.addInstallArtifact(exe, .{
            .dest_dir = .{
                .override = .{
                    .custom = try target.zigTriple(b.allocator),
                },
            },
        });

        release_step.dependOn(&target_output.step);
    }
}
