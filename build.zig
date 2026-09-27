const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const windows = @import("builtin").os.tag == .windows;
    const explicit_lua_library = b.option(std.Build.LazyPath, "lua-library", "Path to a cross-target Lua import library");
    if (windows or explicit_lua_library != null) b.graph.environ_map.put("PKG_CONFIG_ALLOW_SYSTEM_CFLAGS", "1") catch @panic("OOM");
    const lua_library: ?std.Build.LazyPath = explicit_lua_library orelse if (windows) .{ .cwd_relative = b.pathJoin(&.{
        std.mem.trim(u8, b.run(&.{ "cygpath", "-m", std.mem.trim(u8, b.run(&.{ "pkg-config", "--variable=libdir", "lua5.5" }), " \r\n") }), " \r\n"),
        "liblua.dll.a",
    }) } else null;
    const zlua = if (lua_library) |library| b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua55,
        .shared = true,
        .system_lua = true,
        .system_library = library,
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
    const install = b.addInstallArtifact(exe, .{});
    if (target.result.os.tag == .macos) {
        const macos_lua_lib_dir = std.mem.trim(u8, b.run(&.{ "pkg-config", "--variable=libdir", "lua5.5" }), " \r\n");
        const lua_dylib = b.pathJoin(&.{ macos_lua_lib_dir, "liblua.5.5.dylib" });
        const dylib_info = std.mem.trim(u8, b.run(&.{ "otool", "-D", lua_dylib }), " \r\n");
        const lua_install_name = dylib_info[(std.mem.lastIndexOfScalar(u8, dylib_info, '\n') orelse @panic("invalid Lua install name")) + 1 ..];
        exe.root_module.addRPathSpecial("@executable_path");
        exe.root_module.addRPath(.{ .cwd_relative = macos_lua_lib_dir });
        const normalize = b.addSystemCommand(&.{
            "install_name_tool",
            "-change",
            lua_install_name,
            "@rpath/liblua.5.5.dylib",
            b.getInstallPath(.bin, "agent"),
        });
        normalize.step.dependOn(&install.step);
        b.getInstallStep().dependOn(&normalize.step);
    } else {
        b.getInstallStep().dependOn(&install.step);
    }
}
