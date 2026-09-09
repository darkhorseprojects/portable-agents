const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shared_lua = b.option(bool, "shared-lua", "Link Lua 5.5 dynamically") orelse false;
    const system_lua = b.option(bool, "system-lua", "Use an ABI-compatible system Lua 5.5") orelse false;
    const zlua = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua55,
        .shared = shared_lua,
        .system_lua = system_lua,
    });
    const zlua_module = zlua.module("zlua");
    if (!system_lua) {
        const lua = zlua.artifact("lua");
        if (shared_lua) {
            for (zlua_module.link_objects.items, 0..) |object, index| switch (object) {
                .other_step => |step| if (step == lua) {
                    _ = zlua_module.link_objects.orderedRemove(index);
                    break;
                },
                else => {},
            };
            zlua_module.resolved_target = target;
            zlua_module.addLibraryPath(lua.getEmittedBinDirectory());
            zlua_module.linkSystemLibrary("lua", .{ .use_pkg_config = .no });
        } else lua.root_module.pic = true;
    }
    const pa = b.addModule("pa", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zlua", .module = zlua_module }},
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
    const library = b.addLibrary(.{
        .name = "portable_agents",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ffi.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .imports = &.{.{ .name = "zlua", .module = zlua_module }},
        }),
    });
    b.installArtifact(library);
    if (shared_lua) {
        exe.each_lib_rpath = false;
        library.each_lib_rpath = false;
    }
    if (shared_lua and !system_lua) {
        b.installArtifact(zlua.artifact("lua"));
        switch (target.result.os.tag) {
            .linux => {
                exe.root_module.addRPathSpecial("$ORIGIN/../lib");
                library.root_module.addRPathSpecial("$ORIGIN");
            },
            .macos => {
                exe.root_module.addRPathSpecial("@loader_path/../lib");
                library.root_module.addRPathSpecial("@loader_path");
            },
            else => {},
        }
    }
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run agent").dependOn(&run.step);
}
