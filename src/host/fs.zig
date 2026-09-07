const std = @import("std");
const zlua = @import("zlua");
const identity = @import("../identity.zig");

const Allocator = std.mem.Allocator;

pub const Config = struct {
    name: []const u8,
    root: []const u8,
    writable: bool = false,
    eval: bool = false,
    max_bytes: usize = 8 * 1024 * 1024,
};

pub const Grant = struct {
    name: []const u8,
    root: std.Io.Dir,
    writable: bool,
    eval: bool,
    max_bytes: usize,

    pub fn init(allocator: Allocator, io: std.Io, config: Config) !Grant {
        return .{
            .name = try allocator.dupe(u8, config.name),
            .root = try std.Io.Dir.cwd().openDir(io, config.root, .{ .follow_symlinks = false }),
            .writable = config.writable,
            .eval = config.eval,
            .max_bytes = config.max_bytes,
        };
    }

    pub fn deinit(self: *Grant, io: std.Io) void {
        self.root.close(io);
    }

    pub fn push(self: *const Grant, lua: *zlua.Lua, caller: *identity.Caller) void {
        lua.createTable(0, if (self.writable) 2 else 1);
        lua.pushLightUserdata(self);
        lua.pushLightUserdata(caller);
        lua.pushClosure(zlua.wrap(read), 2);
        lua.setField(-2, "read");
        if (self.writable) {
            lua.pushLightUserdata(self);
            lua.pushLightUserdata(caller);
            lua.pushClosure(zlua.wrap(write), 2);
            lua.setField(-2, "write");
        }
    }

    fn read(lua: *zlua.Lua) !i32 {
        const self: *const Grant = @ptrCast(@alignCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?));
        const caller: *identity.Caller = @ptrCast(@alignCast(@constCast(lua.toPointer(zlua.Lua.upvalueIndex(2)).?)));
        if (lua.typeOf(1) != .string) return error.ExpectedBytes;
        var parent = try self.openParent(caller.io, try lua.toString(1));
        defer if (parent.close) parent.dir.close(caller.io);
        const file = try parent.dir.openFile(caller.io, parent.name, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        });
        defer file.close(caller.io);
        var buffer: [8192]u8 = undefined;
        var reader = file.readerStreaming(caller.io, &buffer);
        const data = try reader.interface.allocRemaining(lua.allocator(), .limited(self.max_bytes));
        defer lua.allocator().free(data);
        _ = lua.pushString(data);
        return 1;
    }

    fn write(lua: *zlua.Lua) !i32 {
        const self: *const Grant = @ptrCast(@alignCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?));
        const caller: *identity.Caller = @ptrCast(@alignCast(@constCast(lua.toPointer(zlua.Lua.upvalueIndex(2)).?)));
        if (lua.typeOf(1) != .string or lua.typeOf(2) != .string) return error.ExpectedBytes;
        const data = try lua.toString(2);
        if (data.len > self.max_bytes) return error.FileTooLarge;
        var parent = try self.openParent(caller.io, try lua.toString(1));
        defer if (parent.close) parent.dir.close(caller.io);
        var atomic = try parent.dir.createFileAtomic(caller.io, parent.name, .{ .replace = true });
        defer atomic.deinit(caller.io);
        try atomic.file.writeStreamingAll(caller.io, data);
        try atomic.file.sync(caller.io);
        try atomic.replace(caller.io);
        return 0;
    }

    fn openParent(self: *const Grant, io: std.Io, path: []const u8) !struct { dir: std.Io.Dir, close: bool, name: []const u8 } {
        if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidPath;
        var parts = std.mem.splitScalar(u8, path, '/');
        var current = self.root;
        var owned = false;
        errdefer if (owned) current.close(io);
        var name = parts.next().?;
        while (parts.next()) |next| {
            if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidPath;
            const child = try current.openDir(io, name, .{ .follow_symlinks = false });
            if (owned) current.close(io);
            current = child;
            owned = true;
            name = next;
        }
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidPath;
        return .{ .dir = current, .close = owned, .name = name };
    }
};
