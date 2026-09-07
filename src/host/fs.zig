const std = @import("std");
const zlua = @import("zlua");

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
    io: std.Io,
    writable: bool,
    eval: bool,
    max_bytes: usize,

    pub fn init(allocator: Allocator, io: std.Io, config: Config) !Grant {
        return .{
            .name = try allocator.dupe(u8, config.name),
            .root = try std.Io.Dir.cwd().openDir(io, config.root, .{ .follow_symlinks = false }),
            .io = io,
            .writable = config.writable,
            .eval = config.eval,
            .max_bytes = config.max_bytes,
        };
    }

    pub fn deinit(self: *Grant) void {
        self.root.close(self.io);
    }

    pub fn push(self: *const Grant, lua: *zlua.Lua) void {
        const Callbacks = struct {
            fn grant(state: *zlua.Lua) *const Grant {
                return @ptrCast(@alignCast(state.toPointer(zlua.Lua.upvalueIndex(1)).?));
            }
            fn readValue(state: *zlua.Lua) !i32 {
                const value = grant(state);
                const data = try value.read(state.allocator(), state.checkString(1));
                defer state.allocator().free(data);
                _ = state.pushString(data);
                return 1;
            }
            fn writeValue(state: *zlua.Lua) !i32 {
                try grant(state).write(state.checkString(1), state.checkString(2));
                return 0;
            }
        };
        lua.createTable(0, if (self.writable) 2 else 1);
        lua.pushLightUserdata(self);
        lua.pushClosure(zlua.wrap(Callbacks.readValue), 1);
        lua.setField(-2, "read");
        if (self.writable) {
            lua.pushLightUserdata(self);
            lua.pushClosure(zlua.wrap(Callbacks.writeValue), 1);
            lua.setField(-2, "write");
        }
    }

    fn read(self: *const Grant, allocator: Allocator, path: []const u8) ![]u8 {
        var parent = try self.openParent(path);
        defer if (parent.close) parent.dir.close(self.io);
        const file = try parent.dir.openFile(self.io, parent.name, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        });
        defer file.close(self.io);
        const size = (try file.stat(self.io)).size;
        if (size > self.max_bytes) return error.FileTooLarge;
        const data = try allocator.alloc(u8, @intCast(size));
        errdefer allocator.free(data);
        const read_count = try file.readPositionalAll(self.io, data, 0);
        if (read_count != data.len) return error.UnexpectedEndOfFile;
        return data;
    }

    fn write(self: *const Grant, path: []const u8, data: []const u8) !void {
        if (!self.writable) return error.ReadOnly;
        if (data.len > self.max_bytes) return error.FileTooLarge;
        var parent = try self.openParent(path);
        defer if (parent.close) parent.dir.close(self.io);
        var random: [16]u8 = undefined;
        self.io.random(&random);
        var temp: [36]u8 = ".pa-".* ++ ([_]u8{0} ** 32);
        const hex = "0123456789abcdef";
        for (random, 0..) |byte, index| {
            temp[4 + index * 2] = hex[byte >> 4];
            temp[5 + index * 2] = hex[byte & 15];
        }
        const file = try parent.dir.createFile(self.io, &temp, .{ .exclusive = true });
        var present = true;
        var open = true;
        defer if (present) parent.dir.deleteFile(self.io, &temp) catch {};
        defer if (open) file.close(self.io);
        try file.writeStreamingAll(self.io, data);
        try file.sync(self.io);
        file.close(self.io);
        open = false;
        try parent.dir.rename(&temp, parent.dir, parent.name, self.io);
        present = false;
    }

    fn segments(path: []const u8) !std.mem.SplitIterator(u8, .scalar) {
        if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidPath;
        var validation = std.mem.splitScalar(u8, path, '/');
        while (validation.next()) |segment| {
            if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidPath;
        }
        return std.mem.splitScalar(u8, path, '/');
    }

    fn openParent(self: *const Grant, path: []const u8) !struct { dir: std.Io.Dir, close: bool, name: []const u8 } {
        var parts = try segments(path);
        var current = self.root;
        var owned = false;
        errdefer if (owned) current.close(self.io);
        var name = parts.next().?;
        while (parts.next()) |next| {
            const child = try current.openDir(self.io, name, .{ .follow_symlinks = false });
            if (owned) current.close(self.io);
            current = child;
            owned = true;
            name = next;
        }
        return .{ .dir = current, .close = owned, .name = name };
    }
};
