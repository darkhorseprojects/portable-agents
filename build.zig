const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const system_lua = b.option(bool, "system-lua", "Use a dynamic ABI-compatible system Lua 5.5") orelse false;
    const zlua = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua55,
        .shared = system_lua,
        .system_lua = system_lua,
    });
    const pa = b.addModule("pa", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zlua", .module = zlua.module("zlua") }},
    });
    const exe = b.addExecutable(.{
        .name = "portable-agent",
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
