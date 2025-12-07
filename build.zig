const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library-style module
    const mod = b.addModule("socketcp", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
    });

    // Native executable: `zig build` builds this
    const exe = b.addExecutable(.{
        .name = "socketcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = true,
            // .imports = &.{
            //     .{ .name = "socketcp", .module = mod },
            // },
        }),
    });

    // Only native exe is part of the default install step
    b.installArtifact(exe);

    // zig build run
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Tests (module + exe)
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // -------- zig build all-targets --------
    const all_step = b.step("all-targets", "Build socketcp for common targets");

    const targets = [_]std.Target.Query{
        // Linux
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },

        // macOS
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
    };

    inline for (targets) |t| {
        const cross_target = b.resolveTargetQuery(t);

        const name = std.fmt.comptimePrint(
            "socketcp-{s}-{s}",
            .{ @tagName(t.os_tag.?), @tagName(t.cpu_arch.?) },
        );

        const cross_exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("main.zig"),
                .target = cross_target,
                .optimize = optimize,
                .strip = true,
            }),
        });

        // Install these only when all-targets is requested
        const install_cross = b.addInstallArtifact(cross_exe, .{});
        all_step.dependOn(&install_cross.step);
    }
}
