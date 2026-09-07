const std = @import("std");
const zlua = @import("zlua");
const identity = @import("../identity.zig");

const Allocator = std.mem.Allocator;

pub const Config = struct {
    name: []const u8,
    executable: []const u8,
    cwd: ?[]const u8 = null,
    argv_prefix: []const []const u8 = &.{},
    eval: bool = false,
    max_output_bytes: usize = 8 * 1024 * 1024,
};

pub const Grant = struct {
    name: []const u8,
    executable: []const u8,
    cwd: ?[]const u8,
    argv_prefix: []const []const u8,
    eval: bool,
    max_output_bytes: usize,

    pub fn init(allocator: Allocator, config: Config) !Grant {
        const prefix = try allocator.alloc([]const u8, config.argv_prefix.len);
        for (config.argv_prefix, prefix) |source, *target| target.* = try allocator.dupe(u8, source);
        return .{
            .name = try allocator.dupe(u8, config.name),
            .executable = try allocator.dupe(u8, config.executable),
            .cwd = if (config.cwd) |cwd| try allocator.dupe(u8, cwd) else null,
            .argv_prefix = prefix,
            .eval = config.eval,
            .max_output_bytes = config.max_output_bytes,
        };
    }

    pub fn push(self: *const Grant, lua: *zlua.Lua, caller: *identity.Caller) void {
        lua.createTable(0, 1);
        lua.pushLightUserdata(self);
        lua.pushLightUserdata(caller);
        lua.pushClosure(zlua.wrap(run), 2);
        lua.setField(-2, "run");
    }

    fn run(lua: *zlua.Lua) !i32 {
        const self: *const Grant = @ptrCast(@alignCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?));
        const caller: *identity.Caller = @ptrCast(@alignCast(@constCast(lua.toPointer(zlua.Lua.upvalueIndex(2)).?)));
        if (lua.typeOf(1) != .table) return error.ExpectedTable;
        const count = lua.lenRaw(1);
        const base = try std.math.add(usize, 1, self.argv_prefix.len);
        const argv = try lua.allocator().alloc([]const u8, try std.math.add(usize, base, count));
        defer lua.allocator().free(argv);
        argv[0] = self.executable;
        @memcpy(argv[1..][0..self.argv_prefix.len], self.argv_prefix);
        for (argv[base..], 1..) |*arg, index| {
            _ = lua.getIndex(1, @intCast(index));
            if (lua.typeOf(-1) != .string) return error.ExpectedBytes;
            arg.* = try lua.toString(-1);
            lua.pop(1);
        }
        const result = try std.process.run(lua.allocator(), caller.io, .{
            .argv = argv,
            .cwd = if (self.cwd) |cwd| .{ .path = cwd } else .inherit,
            .stdout_limit = .limited(self.max_output_bytes),
            .stderr_limit = .limited(self.max_output_bytes),
        });
        defer lua.allocator().free(result.stdout);
        defer lua.allocator().free(result.stderr);
        if (result.stdout.len > self.max_output_bytes or result.stderr.len > self.max_output_bytes - result.stdout.len) return error.OutputTooLarge;
        const code = switch (result.term) {
            .exited => |value| value,
            else => return error.AbnormalTermination,
        };
        lua.pushInteger(code);
        _ = lua.pushString(result.stdout);
        _ = lua.pushString(result.stderr);
        return 3;
    }
};
