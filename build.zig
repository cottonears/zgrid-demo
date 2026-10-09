const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });
    const zgrid_dep = b.dependency("zgrid", .{
        .target = target,
        .optimize = optimize,
    });

    const translate_c = b.dependency("translate_c", .{});
    const translator = Translator.init(translate_c, .{
        .c_source_file = b.path("src/sdl.h"),
        .target = target,
        .optimize = optimize,
    });
    translator.linkLibrary(sdl_dep.artifact("SDL3"));

    const exe = b.addExecutable(.{
        .name = "zgrid-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "c", .module = translator.mod },
                .{ .name = "zgrid", .module = zgrid_dep.module("zgrid") },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
}
