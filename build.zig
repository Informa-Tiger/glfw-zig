const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("glfw", .{});

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });

    const glfw = b.addLibrary(.{
        .linkage = .static,
        .name = "glfw",
        .root_module = mod,
    });

    mod.addCSourceFiles(.{
        .root = upstream.path("src"),
    });

    b.installArtifact(glfw);
}
