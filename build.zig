const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3 });

    const exe = b.addExecutable(.{
        .name = "pubix",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dvui", .module = dvui_dep.module("dvui_sdl3") },
                .{ .name = "sdl-backend", .module = dvui_dep.module("sdl3") },
            },
        }),
    });

    const pubix_mod = b.addModule("pubix", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "dvui", .module = dvui_dep.module("dvui_sdl3") },
            .{ .name = "sdl-backend", .module = dvui_dep.module("sdl3") },
        },
    });

    exe.root_module.addImport("pubix", pubix_mod);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const sdl_exe = b.addExecutable(.{
        .name = "pubix-sdl3",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dvui", .module = dvui_dep.module("dvui_sdl3") },
                .{ .name = "sdl-backend", .module = dvui_dep.module("sdl3") },
                .{ .name = "pubix", .module = pubix_mod },
            },
        }),
    });

    const compile_sdl_step = b.step("compile-sdl3", "Compile with SDL3 backend");
    compile_sdl_step.dependOn(&b.addInstallArtifact(sdl_exe, .{}).step);

    const run_sdl_cmd = b.addRunArtifact(sdl_exe);
    run_sdl_cmd.step.dependOn(compile_sdl_step);

    const run_sdl_step = b.step("sdl3", "Run with SDL3 backend");
    run_sdl_step.dependOn(&run_sdl_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = pubix_mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
