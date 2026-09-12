const std = @import("std");
const zlua = @import("zlua");

const Allocator = std.mem.Allocator;

pub const Limits = struct {
    bytes: usize = 16 * 1024 * 1024,
    steps: u64 = 2_000_000,
};

pub const Cancellation = struct {
    value: std.atomic.Value(bool) = .init(false),

    pub fn cancel(self: *Cancellation) void {
        self.value.store(true, .release);
    }

    pub fn canceled(self: *const Cancellation) bool {
        return self.value.load(.acquire);
    }
};

const QuotaAllocator = struct {
    child: Allocator,
    used: usize = 0,
    limit: usize,

    fn allocator(self: *QuotaAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = Allocator.noResize, .remap = remap, .free = free } };
    }

    fn alloc(pointer: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *QuotaAllocator = @ptrCast(@alignCast(pointer));
        if (len > self.limit -| self.used) return null;
        const result = self.child.rawAlloc(len, alignment, address) orelse return null;
        self.used += len;
        return result;
    }

    fn remap(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) ?[*]u8 {
        const self: *QuotaAllocator = @ptrCast(@alignCast(pointer));
        if (len > memory.len and len - memory.len > self.limit -| self.used) return null;
        const result = self.child.rawRemap(memory, alignment, len, address) orelse return null;
        if (len > memory.len) self.used += len - memory.len else self.used -= memory.len - len;
        return result;
    }

    fn free(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *QuotaAllocator = @ptrCast(@alignCast(pointer));
        self.child.rawFree(memory, alignment, address);
        self.used -= memory.len;
    }
};

pub const Vm = struct {
    lua: *zlua.Lua,
    quota: QuotaAllocator,
    io: std.Io,
    cancellation: *Cancellation,
    owner: *anyopaque,
    steps_left: u64,

    pub fn init(self: *Vm, allocator: Allocator, io: std.Io, limits: Limits, cancellation: *Cancellation, context: *anyopaque) !void {
        self.* = .{ .lua = undefined, .quota = .{ .child = allocator, .limit = limits.bytes }, .io = io, .cancellation = cancellation, .owner = context, .steps_left = limits.steps };
        self.lua = try zlua.Lua.init(self.quota.allocator());
        @as(**Vm, @ptrCast(@alignCast(self.lua.getExtraSpace().ptr))).* = self;
        self.lua.setHook(zlua.wrap(hook), .{ .count = true }, 1000);
    }

    pub fn deinit(self: *Vm) void {
        self.lua.deinit();
    }

    pub fn protect(self: *Vm, args: zlua.Lua.ProtectedCallArgs) !void {
        self.lua.protectedCall(args) catch return if (self.cancellation.canceled()) error.Canceled else error.LuaFailure;
    }
};

pub fn vm(lua: *zlua.Lua) *Vm {
    return @as(**Vm, @ptrCast(@alignCast(lua.getExtraSpace().ptr))).*;
}

pub fn owner(comptime T: type, lua: *zlua.Lua) *T {
    return @ptrCast(@alignCast(vm(lua).owner));
}

pub fn bytes(lua: *zlua.Lua, index: i32) ![]const u8 {
    return if (lua.typeOf(index) == .string) lua.toString(index) else error.ExpectedBytes;
}

pub fn propagate(cancellation: *Cancellation, result: anytype) @TypeOf(result) {
    return result catch |err| {
        if (err == error.Canceled) cancellation.cancel();
        return err;
    };
}

fn hook(lua: *zlua.Lua, _: zlua.Event, _: *zlua.DebugInfo) void {
    const self = vm(lua);
    self.io.checkCancel() catch {
        self.cancellation.cancel();
        lua.raiseErrorStr("canceled", .{});
    };
    if (self.steps_left < 1000) lua.raiseErrorStr("step limit exceeded", .{});
    self.steps_left -= 1000;
}
