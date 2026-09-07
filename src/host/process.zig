const std = @import("std");
const zlua = @import("zlua");

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
    io: std.Io,

    pub fn init(allocator: Allocator, io: std.Io, config: Config) !Grant {
        const prefix = try allocator.alloc([]const u8, config.argv_prefix.len);
        for (config.argv_prefix, prefix) |source, *target| target.* = try allocator.dupe(u8, source);
        return .{
            .name = try allocator.dupe(u8, config.name),
            .executable = try allocator.dupe(u8, config.executable),
            .cwd = if (config.cwd) |cwd| try allocator.dupe(u8, cwd) else null,
            .argv_prefix = prefix,
            .eval = config.eval,
            .max_output_bytes = config.max_output_bytes,
            .io = io,
        };
    }

    pub fn push(self: *const Grant, lua: *zlua.Lua) void {
        const Callback = struct {
            fn runValue(state: *zlua.Lua) !i32 {
                const grant: *const Grant = @ptrCast(@alignCast(state.toPointer(zlua.Lua.upvalueIndex(1)).?));
                const result = try grant.run(state.allocator(), state, 1);
                defer state.allocator().free(result.stdout);
                defer state.allocator().free(result.stderr);
                state.pushInteger(result.code);
                _ = state.pushString(result.stdout);
                _ = state.pushString(result.stderr);
                return 3;
            }
        };
        lua.createTable(0, 1);
        lua.pushLightUserdata(self);
        lua.pushClosure(zlua.wrap(Callback.runValue), 1);
        lua.setField(-2, "run");
    }

    fn denseArgv(self: *const Grant, allocator: Allocator, lua: *zlua.Lua, index: i32) ![]const []const u8 {
        if (lua.typeOf(index) != .table) return error.ExpectedTable;
        const count = lua.lenRaw(index);
        var argv: std.ArrayList([]const u8) = .empty;
        errdefer argv.deinit(allocator);
        try argv.append(allocator, self.executable);
        try argv.appendSlice(allocator, self.argv_prefix);
        for (0..count) |offset| {
            _ = lua.getIndex(index, @intCast(offset + 1));
            const value = try lua.toString(-1);
            try argv.append(allocator, value);
            lua.pop(1);
        }
        return argv.toOwnedSlice(allocator);
    }

    fn run(self: *const Grant, allocator: Allocator, lua: *zlua.Lua, index: i32) !struct { code: i32, stdout: []u8, stderr: []u8 } {
        const argv = try self.denseArgv(allocator, lua, index);
        defer allocator.free(argv);
        const result = try std.process.run(allocator, self.io, .{
            .argv = argv,
            .cwd = if (self.cwd) |cwd| .{ .path = cwd } else .inherit,
            .stdout_limit = .limited(self.max_output_bytes),
            .stderr_limit = .limited(self.max_output_bytes),
        });
        errdefer allocator.free(result.stdout);
        errdefer allocator.free(result.stderr);
        if (result.stdout.len + result.stderr.len > self.max_output_bytes) return error.OutputTooLarge;
        const code: i32 = switch (result.term) {
            .exited => |value| value,
            else => return error.AbnormalTermination,
        };
        return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
    }
};
