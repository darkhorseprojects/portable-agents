const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const system_lua = b.option(bool, "system-lua", "Use a dynamic ABI-compatible system Lua 5.5") orelse false;
    const lua_include: ?[]const u8 = if (system_lua)
        b.option([]const u8, "lua-include", "Directory containing Lua 5.5 headers") orelse @panic("-Dlua-include is required with -Dsystem-lua=true")
    else
        null;
    const lua_headers: ?[]const std.Build.LazyPath = if (lua_include) |path| &.{.{ .cwd_relative = path }} else null;
    const zlua = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua55,
        .shared = system_lua,
        .system_lua = system_lua,
        .additional_system_headers = lua_headers,
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
    if (system_lua and target.result.os.tag != .windows) {
        exe.root_module.addRPathSpecial(if (target.result.os.tag == .macos) "@loader_path" else "$ORIGIN");
    }
    b.installArtifact(exe);
}
