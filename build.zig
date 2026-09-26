const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const windows = @import("builtin").os.tag == .windows;
    if (windows) b.graph.environ_map.put("PKG_CONFIG_ALLOW_SYSTEM_CFLAGS", "1") catch @panic("OOM");
    const lua_lib_dir = if (windows)
        std.mem.trim(u8, b.run(&.{ "cygpath", "-m", std.mem.trim(u8, b.run(&.{ "pkg-config", "--variable=libdir", "lua5.5" }), " \r\n") }), " \r\n")
    else
        undefined;
    const lua_library: std.Build.LazyPath = if (windows)
        .{ .cwd_relative = b.pathJoin(&.{ lua_lib_dir, "liblua.dll.a" }) }
    else
        undefined;
    const zlua = if (windows) b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua55,
        .shared = true,
        .system_lua = true,
        .system_library = lua_library,
    }) else b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua55,
        .shared = true,
        .system_lua = true,
    });
    const pa = b.addModule("pa", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zlua", .module = zlua.module("zlua") }},
    });
    const exe = b.addExecutable(.{
        .name = "agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .imports = &.{.{ .name = "pa", .module = pa }},
        }),
    });
    b.installArtifact(exe);
}
