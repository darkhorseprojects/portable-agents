const std = @import("std");
const builtin = @import("builtin");
const zlua = @import("zlua");
const lua_state = @import("../lua.zig");

const Root = struct {
    dir: std.Io.Dir,
    open: bool,
};

pub fn install(lua: *zlua.Lua) !void {
    try lua.newMetatable("pa.fs.root");
    lua.pushFunction(zlua.wrap(close));
    lua.setField(-2, "__gc");
    lua.pop(1);
    lua.pushFunction(zlua.wrap(create));
    lua.setField(-2, "fs");
}

fn create(lua: *zlua.Lua) !i32 {
    return lua_state.propagate(lua_state.control(lua).cancellation, createValue(lua));
}

fn createValue(lua: *zlua.Lua) !i32 {
    if (lua.typeOf(1) != .string) return error.ExpectedPath;
    const path = try lua.toString(1);
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    const root = lua.newUserdata(Root, 0);
    root.* = .{ .dir = undefined, .open = false };
    lua.setMetatableRegistry("pa.fs.root");
    root.dir = try std.Io.Dir.cwd().openDir(lua_state.control(lua).io, path, .{});
    root.open = true;
    const root_index = lua.getTop();
    lua.createTable(0, 2);
    inline for (.{ .{ "read", read }, .{ "write", write } }) |field| {
        lua.pushValue(root_index);
        lua.pushClosure(zlua.wrap(field[1]), 1);
        lua.setField(-2, field[0]);
    }
    lua.remove(root_index);
    return 1;
}

fn close(lua: *zlua.Lua) i32 {
    const root = lua.toUserdata(Root, 1) catch return 0;
    if (root.open) root.dir.close(lua_state.control(lua).io);
    root.open = false;
    return 0;
}

fn read(lua: *zlua.Lua) !i32 {
    return lua_state.propagate(lua_state.control(lua).cancellation, readValue(lua));
}

fn readValue(lua: *zlua.Lua) !i32 {
    const root = try lua.toUserdata(Root, zlua.Lua.upvalueIndex(1));
    if (!root.open or lua.typeOf(1) != .string) return error.ExpectedPath;
    const io = lua_state.control(lua).io;
    var parent = try openParent(root, io, try lua.toString(1));
    defer if (parent.close) parent.dir.close(io);
    const file = try parent.dir.openFile(io, parent.name, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const data = try reader.interface.allocRemaining(lua.allocator(), .unlimited);
    defer lua.allocator().free(data);
    _ = lua.pushString(data);
    return 1;
}

fn write(lua: *zlua.Lua) !i32 {
    return lua_state.propagate(lua_state.control(lua).cancellation, writeValue(lua));
}

fn writeValue(lua: *zlua.Lua) !i32 {
    const root = try lua.toUserdata(Root, zlua.Lua.upvalueIndex(1));
    if (!root.open or lua.typeOf(1) != .string or lua.typeOf(2) != .string) return error.ExpectedBytes;
    const io = lua_state.control(lua).io;
    var parent = try openParent(root, io, try lua.toString(1));
    defer if (parent.close) parent.dir.close(io);
    const permissions = if (parent.dir.statFile(io, parent.name, .{ .follow_symlinks = false })) |stat|
        stat.permissions
    else |err| switch (err) {
        error.FileNotFound => if (builtin.os.tag == .windows) .default_file else std.Io.File.Permissions.fromMode(0o600),
        else => return err,
    };
    var atomic = try parent.dir.createFileAtomic(io, parent.name, .{ .replace = true, .permissions = permissions });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, try lua.toString(2));
    try atomic.file.sync(io);
    try atomic.replace(io);
    return 0;
}

fn openParent(root: *const Root, io: std.Io, path: []const u8) !struct { dir: std.Io.Dir, close: bool, name: []const u8 } {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null or
        (builtin.os.tag == .windows and std.mem.indexOfScalar(u8, path, ':') != null)) return error.InvalidPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    var current = root.dir;
    var owned = false;
    errdefer if (owned) current.close(io);
    var name = parts.next().?;
    while (parts.next()) |next| {
        if (!validPart(name)) return error.InvalidPath;
        const child = try current.openDir(io, name, .{ .follow_symlinks = false });
        if (owned) current.close(io);
        current = child;
        owned = true;
        name = next;
    }
    if (!validPart(name)) return error.InvalidPath;
    return .{ .dir = current, .close = owned, .name = name };
}

fn validPart(part: []const u8) bool {
    return part.len != 0 and std.mem.indexOfScalar(u8, part, 0) == null and
        !std.mem.eql(u8, part, ".") and !std.mem.eql(u8, part, "..");
}
