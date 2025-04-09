const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const platform: enum { apple, win32, posix } = if (target.result.os.tag.isDarwin())
        .apple
    else if (target.result.os.tag == .windows)
        .win32
    else
        .posix;

    const x11 = (b.option(bool, "x11", "Build support for X11; ignored on mismatch with target") orelse true) and platform == .posix;
    const wayland = (b.option(bool, "wayland", "Build support for Wayland; ignored on mismatch with target") orelse true) and platform == .posix;

    const linkage = b.option(std.builtin.LinkMode, "linkage", "link mode of glfw library") orelse .static;

    const x11_headers = b.option(std.Build.LazyPath, "x11-headers", "Include path for X11 stuff");

    const xkbcommon_headers = b.option(std.Build.LazyPath, "xkbcommon-headers", "Include path for xkbcommon") orelse x11_headers;

    const x11_libraries = [_][]const u8{ "libX11", "xorgproto", "libXcursor", "libXrandr", "libXrender", "libXinerama", "libXi", "libXext", "libXfixes" };
    var x11_header_paths: [x11_libraries.len]?std.Build.LazyPath = undefined;

    inline for (x11_libraries, &x11_header_paths) |lib, *header_path| {
        header_path.* = b.option(std.Build.LazyPath, lib ++ "-headers", "Include path for " ++ lib) orelse x11_headers;
    }

    const wayland_headers = b.option(std.Build.LazyPath, "wayland-headers", "Include path for wayland");
    const wayland_protocol_headers = b.option(std.Build.LazyPath, "wayland-protocol-headers", "Include path for wayland protocol");

    const upstream = b.dependency("glfw", .{});

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(b.allocator);

    try files.appendSlice(b.allocator, &.{
        "context.c",
        "init.c",
        "input.c",
        "monitor.c",
        "platform.c",
        "vulkan.c",
        "window.c",
        "egl_context.c",
        "osmesa_context.c",
        "null_init.c",
        "null_monitor.c",
        "null_window.c",
        "null_joystick.c",
    });

    try files.appendSlice(
        b.allocator,
        switch (platform) {
            .apple => &.{ "posix_module.c", "cocoa_time.c", "posix_thread.c" },
            .win32 => &.{ "win32_module.c", "win32_time.c", "win32_thread.c" },
            .posix => &.{ "posix_module.c", "posix_time.c", "posix_thread.c" },
        },
    );

    if (platform == .apple) {
        mod.addCMacro("_GLFW_COCOA", "");
        try files.appendSlice(b.allocator, &.{
            "cocoa_init.m",
            "cocoa_joystick.m",
            "cocoa_monitor.m",
            "cocoa_window.m",
            "nsgl_context.m",
        });

        mod.linkFramework("Cocoa", .{});
        mod.linkFramework("IOKit", .{});
        mod.linkFramework("CoreFoundation", .{});
    }

    if (platform == .win32) {
        mod.addCMacro("_GLFW_WIN32", "");
        try files.appendSlice(b.allocator, &.{
            "win32_init.c",
            "win32_joystick.c",
            "win32_monitor.c",
            "win32_window.c",
            "wgl_context.c",
        });

        mod.linkSystemLibrary("gdi32", .{});

        if (linkage == .dynamic) {
            const resource_file = b.addConfigHeader(
                .{ .style = .{ .cmake = upstream.path("src/glfw.rc.in") } },
                .{ .GLFW_VERSION_MAJOR = 3, .GLFW_VERSION_MINOR = 4, .GLFW_VERSION_PATCH = 0, .GLFW_VERSION = "3.4.0" },
            );

            mod.addWin32ResourceFile(.{ .file = b.addWriteFiles().addCopyFile(resource_file.getOutput(), "glfw.rc") });
        }
    }

    if (x11) {
        mod.addCMacro("_GLFW_X11", "");
        try files.appendSlice(b.allocator, &.{
            "x11_init.c",
            "x11_monitor.c",
            "x11_window.c",
            "glx_context.c",
        });

        for (x11_libraries, x11_header_paths) |lib, header_path| {
            if (header_path) |path| {
                mod.addIncludePath(path);
            } else if (b.lazyDependency(lib, .{})) |dep| {
                mod.addIncludePath(dep.path("include"));
            }
        }
    }

    if (wayland) {
        mod.addCMacro("_GLFW_WAYLAND", "");
        try files.appendSlice(b.allocator, &.{
            "wl_init.c",
            "wl_monitor.c",
            "wl_window.c",
        });

        // const h2 = b.option(std.Build.LazyPath, "wayland-protocol-headers", "Path to wayland protocol headers") orelse @panic("message: []const u8");
        // mod.addIncludePath(h2);

        if (wayland_headers) |path| {
            mod.addIncludePath(path);
        } else if (b.lazyDependency("wayland_headers", .{})) |dep| {
            mod.addIncludePath(dep.path("wayland"));
        }
        if (wayland_protocol_headers) |path| {
            mod.addIncludePath(path);
        } else if (b.lazyDependency("wayland_headers", .{})) |dep| {
            mod.addIncludePath(dep.path("wayland-protocols"));
        }

        if (xkbcommon_headers) |path| {
            mod.addIncludePath(path);
        } else if (b.lazyDependency("xkbcommon", .{})) |dep| {
            mod.addIncludePath(dep.path("include"));
        }
    }

    if (x11 or wayland) {
        if (target.result.os.tag == .linux) {
            try files.append(b.allocator, "linux_joystick.c");
        }
        try files.appendSlice(b.allocator, &.{ "posix_poll.c", "xkb_unicode.c" });
    }

    if (linkage == .dynamic) {
        mod.addCMacro("_GLFW_BUILD_DLL", "");
    }

    mod.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = files.items,
        .flags = &.{ "-Wall", "-Wpedantic" },
    });

    const glfw = b.addLibrary(.{
        .linkage = linkage,
        .name = "glfw",
        .root_module = mod,
    });

    b.installArtifact(glfw);
}
