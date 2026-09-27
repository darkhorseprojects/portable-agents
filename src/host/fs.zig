const std = @import("std");
const builtin = @import("builtin");
const zlua = @import("zlua");
const lua_state = @import("../lua.zig");

const Root = struct {
    dir: ?std.Io.Dir,
};

pub fn install(lua: *zlua.Lua, package_dir: *const std.Io.Dir) !void {
    try lua.newMetatable("pa.fs.root");
    lua.createTable(0, 2);
    lua.pushFunction(zlua.wrap(read));
    lua.setField(-2, "read");
    lua.pushFunction(zlua.wrap(write));
    lua.setField(-2, "write");
    lua.setField(-2, "__index");
    lua.pushFunction(zlua.wrap(close));
    lua.setField(-2, "__gc");
    lua.pushFunction(zlua.wrap(close));
    lua.setField(-2, "__close");
    lua.pop(1);
    lua.pushLightUserdata(@ptrCast(@constCast(package_dir)));
    lua.pushClosure(zlua.wrap(create), 1);
    lua.setField(-2, "fs");
}

fn create(lua: *zlua.Lua) !i32 {
    errdefer lua_state.control(lua).io.checkCancel() catch lua_state.control(lua).cancellation.cancel();
    const package_dir: *const std.Io.Dir = @ptrCast(@alignCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?));
    const io = lua_state.control(lua).io;
    const path = if (lua.typeOf(1) == .none or lua.isNil(1)) null else blk: {
        if (lua.typeOf(1) != .string) return error.ExpectedPath;
        break :blk try lua.toString(1);
    };
    const root = lua.newUserdata(Root, 0);
    root.* = .{ .dir = null };
    lua.setMetatableRegistry("pa.fs.root");
    if (path == null) {
        root.dir = try package_dir.openDir(io, ".", .{ .follow_symlinks = false });
    } else if (std.fs.path.isAbsolute(path.?)) {
        root.dir = try std.Io.Dir.openDirAbsolute(io, path.?, .{ .follow_symlinks = false });
    } else {
        var parent = try openParent(package_dir.*, io, path.?);
        defer if (parent.owns_dir) parent.dir.close(io);
        root.dir = try parent.dir.openDir(io, parent.name, .{ .follow_symlinks = false });
    }
    return 1;
}

fn close(lua: *zlua.Lua) i32 {
    const root = lua.toUserdata(Root, 1) catch return 0;
    if (root.dir) |dir| dir.close(lua_state.control(lua).io);
    root.dir = null;
    return 0;
}

fn read(lua: *zlua.Lua) !i32 {
    errdefer lua_state.control(lua).io.checkCancel() catch lua_state.control(lua).cancellation.cancel();
    if (lua.typeOf(2) != .string) return error.ExpectedPath;
    const root = (try lua.toUserdata(Root, 1)).dir orelse return error.ExpectedPath;
    const io = lua_state.control(lua).io;
    var parent = try openParent(root, io, try lua.toString(2));
    defer if (parent.owns_dir) parent.dir.close(io);
    var file = try parent.dir.openFile(io, parent.name, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer file.close(io);
    if (builtin.os.tag == .windows) file.flags.nonblocking = true;
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const data = try reader.interface.allocRemaining(lua.allocator(), .unlimited);
    defer lua.allocator().free(data);
    _ = lua.pushString(data);
    return 1;
}

fn write(lua: *zlua.Lua) !i32 {
    errdefer lua_state.control(lua).io.checkCancel() catch lua_state.control(lua).cancellation.cancel();
    if (lua.typeOf(2) != .string or lua.typeOf(3) != .string) return error.ExpectedBytes;
    const root = (try lua.toUserdata(Root, 1)).dir orelse return error.ExpectedBytes;
    const io = lua_state.control(lua).io;
    var parent = try openParent(root, io, try lua.toString(2));
    defer if (parent.owns_dir) parent.dir.close(io);
    const permissions = if (parent.dir.statFile(io, parent.name, .{ .follow_symlinks = false })) |stat|
        stat.permissions
    else |stat_error| switch (stat_error) {
        error.FileNotFound => if (builtin.os.tag == .windows) .default_file else std.Io.File.Permissions.fromMode(0o600),
        else => return stat_error,
    };
    var atomic = try parent.dir.createFileAtomic(io, parent.name, .{ .replace = true, .permissions = permissions });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, try lua.toString(3));
    try atomic.file.sync(io);
    try atomic.replace(io);
    return 0;
}

fn openParent(root: std.Io.Dir, io: std.Io, path: []const u8) !struct { dir: std.Io.Dir, owns_dir: bool, name: []const u8 } {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null or
        (builtin.os.tag == .windows and std.mem.indexOfScalar(u8, path, ':') != null)) return error.InvalidPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    var current = root;
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
    return .{ .dir = current, .owns_dir = owned, .name = name };
}

fn validPart(part: []const u8) bool {
    return part.len != 0 and std.mem.indexOfScalar(u8, part, 0) == null and
        !std.mem.eql(u8, part, ".") and !std.mem.eql(u8, part, "..");
}
