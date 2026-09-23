const std = @import("std");
const zlua = @import("zlua");

const Allocator = std.mem.Allocator;
const hook_interval = 1_000;

pub const Limits = struct {
    memory_bytes: usize = 16 * 1024 * 1024,
    instructions: u64 = 2_000_000,
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

pub const Quota = struct {
    backing: Allocator,
    used_bytes: usize = 0,
    max_bytes: usize,

    pub fn allocator(self: *Quota) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = Allocator.noResize, .remap = remap, .free = free } };
    }

    fn alloc(pointer: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *Quota = @ptrCast(@alignCast(pointer));
        if (len > self.max_bytes -| self.used_bytes) return null;
        const result = self.backing.rawAlloc(len, alignment, address) orelse return null;
        self.used_bytes += len;
        return result;
    }

    fn remap(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) ?[*]u8 {
        const self: *Quota = @ptrCast(@alignCast(pointer));
        if (len > memory.len and len - memory.len > self.max_bytes -| self.used_bytes) return null;
        const result = self.backing.rawRemap(memory, alignment, len, address) orelse return null;
        if (len > memory.len) self.used_bytes += len - memory.len else self.used_bytes -= memory.len - len;
        return result;
    }

    fn free(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *Quota = @ptrCast(@alignCast(pointer));
        self.backing.rawFree(memory, alignment, address);
        self.used_bytes -= memory.len;
    }
};

pub const Event = union(enum) {
    message: []const u8,
    append: []const u8,
    log: []const u8,
    traceback: []const u8,
};

pub const EventSink = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, Event) anyerror!void,

    pub fn emit(self: EventSink, event: Event) !void {
        try self.write(self.context, event);
    }
};

pub const Control = struct {
    io: std.Io,
    cancellation: *Cancellation,
    remaining_instructions: u64,
    sink: ?EventSink = null,
};

pub fn attach(state: *zlua.Lua, value: *Control) void {
    @as(**Control, @ptrCast(@alignCast(state.getExtraSpace().ptr))).* = value;
    state.setHook(zlua.wrap(hook), .{ .count = true }, hook_interval);
}

pub fn control(state: *zlua.Lua) *Control {
    return @as(**Control, @ptrCast(@alignCast(state.getExtraSpace().ptr))).*;
}

pub fn protect(state: *zlua.Lua, args: zlua.Lua.ProtectedCallArgs) !void {
    state.pushFunction(zlua.wrap(traceback));
    state.insert(-args.args - 2);
    const handler = state.getTop() - args.args - 1;
    const result = state.protectedCall(.{ .args = args.args, .results = args.results, .msg_handler = handler });
    if (result) |_| {
        state.remove(handler);
    } else |_| {
        if (control(state).sink) |sink| {
            const detail = state.toString(-1) catch "LuaFailure";
            var end = @min(2048, detail.len);
            while (end > 0 and !std.unicode.utf8ValidateSlice(detail[0..end])) end -= 1;
            sink.emit(.{ .traceback = if (end > 0) detail[0..end] else "LuaFailure" }) catch {};
        }
        state.pop(1);
        state.remove(handler);
        return if (control(state).cancellation.canceled()) error.Canceled else error.LuaFailure;
    }
}

pub fn bytes(state: *zlua.Lua, index: i32) ![]const u8 {
    return if (state.typeOf(index) == .string) state.toString(index) else error.ExpectedBytes;
}

pub fn traceback(state: *zlua.Lua) i32 {
    const message = if (state.typeOf(1) == .string) state.toString(1) catch null else null;
    state.traceback(state, message, 1);
    return 1;
}

pub fn transfer(source: *zlua.Lua, target: *zlua.Lua, index: i32, depth: u8) !void {
    if (depth == 64) return error.ValueDepthExceeded;
    try source.checkStack(2);
    try target.checkStack(2);
    switch (source.typeOf(index)) {
        .nil => target.pushNil(),
        .boolean => target.pushBoolean(source.toBoolean(index)),
        .number => if (source.isInteger(index))
            target.pushInteger(try source.toInteger(index))
        else
            target.pushNumber(try source.toNumber(index)),
        .string => _ = target.pushString(try source.toString(index)),
        .table => {
            target.createTable(0, 0);
            const table = source.absIndex(index);
            source.pushNil();
            while (source.next(table)) {
                const key = source.typeOf(-2);
                if (key != .string and (key != .number or !source.isInteger(-2) or (try source.toInteger(-2)) < 1))
                    return error.UnsupportedValueKey;
                try transfer(source, target, -2, depth + 1);
                try transfer(source, target, -1, depth + 1);
                target.setTableRaw(-3);
                source.pop(1);
            }
        },
        else => return error.UnsupportedValue,
    }
}

fn hook(state: *zlua.Lua, _: zlua.Event, _: *zlua.DebugInfo) void {
    const value = control(state);
    value.io.checkCancel() catch {
        value.cancellation.cancel();
        state.raiseErrorStr("canceled", .{});
    };
    if (value.remaining_instructions < hook_interval) state.raiseErrorStr("instruction limit exceeded", .{});
    value.remaining_instructions -= hook_interval;
}
