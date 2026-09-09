const std = @import("std");
const builtin = @import("builtin");
const zlua = @import("zlua");

const Root = struct {
    dir: std.Io.Dir,
    io: *const std.Io,
    canceled: *std.atomic.Value(bool),
    open: bool,
};

pub fn install(lua: *zlua.Lua, io: *const std.Io, canceled: *std.atomic.Value(bool)) !void {
    try lua.newMetatable("pa.fs.root");
    lua.pushFunction(zlua.wrap(close));
    lua.setField(-2, "__gc");
    lua.pop(1);
    lua.pushLightUserdata(io);
    lua.pushLightUserdata(canceled);
    lua.pushClosure(zlua.wrap(create), 2);
    lua.setField(-2, "fs");
}

fn create(lua: *zlua.Lua) !i32 {
    const canceled: *std.atomic.Value(bool) = @ptrCast(@alignCast(@constCast(lua.toPointer(zlua.Lua.upvalueIndex(2)).?)));
    return createValue(lua) catch |err| {
        if (err == error.Canceled) canceled.store(true, .release);
        return err;
    };
}

fn createValue(lua: *zlua.Lua) !i32 {
    if (lua.typeOf(1) != .string) return error.ExpectedPath;
    const io: *const std.Io = @ptrCast(@alignCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?));
    const canceled: *std.atomic.Value(bool) = @ptrCast(@alignCast(@constCast(lua.toPointer(zlua.Lua.upvalueIndex(2)).?)));
    const root = lua.newUserdata(Root, 0);
    root.* = .{ .dir = undefined, .io = io, .canceled = canceled, .open = false };
    lua.setMetatableRegistry("pa.fs.root");
    root.dir = try std.Io.Dir.cwd().openDir(io.*, try lua.toString(1), .{});
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
    if (root.open) root.dir.close(root.io.*);
    root.open = false;
    return 0;
}

fn read(lua: *zlua.Lua) !i32 {
    const root = try lua.toUserdata(Root, zlua.Lua.upvalueIndex(1));
    return readValue(lua) catch |err| {
        if (err == error.Canceled) root.canceled.store(true, .release);
        return err;
    };
}

fn readValue(lua: *zlua.Lua) !i32 {
    const root = try lua.toUserdata(Root, zlua.Lua.upvalueIndex(1));
    if (!root.open or lua.typeOf(1) != .string) return error.ExpectedPath;
    var parent = try openParent(root, try lua.toString(1));
    defer if (parent.close) parent.dir.close(root.io.*);
    const file = try parent.dir.openFile(root.io.*, parent.name, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer file.close(root.io.*);
    var buffer: [8192]u8 = undefined;
    var reader = file.readerStreaming(root.io.*, &buffer);
    const data = try reader.interface.allocRemaining(lua.allocator(), .unlimited);
    defer lua.allocator().free(data);
    _ = lua.pushString(data);
    return 1;
}

fn write(lua: *zlua.Lua) !i32 {
    const root = try lua.toUserdata(Root, zlua.Lua.upvalueIndex(1));
    return writeValue(lua) catch |err| {
        if (err == error.Canceled) root.canceled.store(true, .release);
        return err;
    };
}

fn writeValue(lua: *zlua.Lua) !i32 {
    const root = try lua.toUserdata(Root, zlua.Lua.upvalueIndex(1));
    if (!root.open or lua.typeOf(1) != .string or lua.typeOf(2) != .string) return error.ExpectedBytes;
    var parent = try openParent(root, try lua.toString(1));
    defer if (parent.close) parent.dir.close(root.io.*);
    var atomic = try parent.dir.createFileAtomic(root.io.*, parent.name, .{ .replace = true });
    defer atomic.deinit(root.io.*);
    try atomic.file.writeStreamingAll(root.io.*, try lua.toString(2));
    try atomic.file.sync(root.io.*);
    try atomic.replace(root.io.*);
    return 0;
}

fn openParent(root: *const Root, path: []const u8) !struct { dir: std.Io.Dir, close: bool, name: []const u8 } {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null or
        (builtin.os.tag == .windows and std.mem.indexOfScalar(u8, path, ':') != null)) return error.InvalidPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    var current = root.dir;
    var owned = false;
    errdefer if (owned) current.close(root.io.*);
    var name = parts.next().?;
    while (parts.next()) |next| {
        if (!validPart(name)) return error.InvalidPath;
        const child = try current.openDir(root.io.*, name, .{ .follow_symlinks = false });
        if (owned) current.close(root.io.*);
        current = child;
        owned = true;
        name = next;
    }
    if (!validPart(name)) return error.InvalidPath;
    return .{ .dir = current, .close = owned, .name = name };
}

fn validPart(part: []const u8) bool {
    return part.len != 0 and !std.mem.eql(u8, part, ".") and !std.mem.eql(u8, part, "..");
}
