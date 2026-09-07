const std = @import("std");
const zlua = @import("zlua");
const package = @import("package.zig");
const host = @import("host.zig");
const identity = @import("identity.zig");

const Allocator = std.mem.Allocator;
const HookDebug = @typeInfo(@typeInfo(zlua.CHookFn).pointer.child).@"fn".params[1].type.?;

pub const Scope = enum { trusted, eval };

pub const Exec = struct {
    image: *package.Image,
    host: *host.Host,
    caller: *identity.Caller,
    self: *const identity.Handle,
    scope: Scope,
    steps_left: u64,
    lua_bytes: usize,
    lua_steps: u64,

    fn luaHandle(state: *zlua.Lua) !i32 {
        const value = exec(state);
        if (state.typeOf(1) != .string) return error.ExpectedBytes;
        try identity.pushHandle(state, value.caller.allocator, try identity.decodeHandle(try state.toString(1)));
        return 1;
    }

    fn luaSelf(state: *zlua.Lua) !i32 {
        const value = exec(state);
        try identity.pushHandle(state, value.caller.allocator, value.self.*);
        return 1;
    }

    fn luaCall(state: *zlua.Lua) !i32 {
        const value = exec(state);
        const handle = try identity.decodeHandle(try bytes(state, 1));
        const output = try handle.call(value.caller, try bytes(state, 2));
        defer value.caller.allocator.free(output);
        _ = state.pushString(output);
        return 1;
    }
};

pub const Quota = struct {
    child: Allocator,
    used: usize = 0,
    limit: usize,

    pub fn allocator(self: *Quota) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *Quota = @ptrCast(@alignCast(context));
        if (len > self.limit -| self.used) return null;
        const result = self.child.rawAlloc(len, alignment, address) orelse return null;
        self.used += len;
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, address: usize) bool {
        const self: *Quota = @ptrCast(@alignCast(context));
        if (new_len > memory.len and new_len - memory.len > self.limit -| self.used) return false;
        if (!self.child.rawResize(memory, alignment, new_len, address)) return false;
        if (new_len > memory.len) self.used += new_len - memory.len else self.used -= memory.len - new_len;
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, address: usize) ?[*]u8 {
        const self: *Quota = @ptrCast(@alignCast(context));
        if (new_len > memory.len and new_len - memory.len > self.limit -| self.used) return null;
        const result = self.child.rawRemap(memory, alignment, new_len, address) orelse return null;
        if (new_len > memory.len) self.used += new_len - memory.len else self.used -= memory.len - new_len;
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *Quota = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, address);
        self.used -= memory.len;
    }
};

const Job = struct {
    source: []const u8,
    input: []const u8,
    outcome: union(enum) { pending, returned: []u8, failed: anyerror } = .pending,

    fn start(self: *Job, parent: *const Exec) std.Io.Cancelable!void {
        evalOne(self, parent) catch |err| {
            parent.caller.observe(err);
            self.outcome = .{ .failed = err };
            if (err == error.Canceled) return error.Canceled;
        };
    }

    fn deinit(self: *Job, allocator: Allocator) void {
        switch (self.outcome) {
            .returned => |output| allocator.free(output),
            else => {},
        }
    }
};

pub fn setExec(state: *zlua.Lua, value: *Exec) void {
    const pointer: *Exec = value;
    @memcpy(state.getExtraSpace()[0..@sizeOf(*Exec)], std.mem.asBytes(&pointer));
}

pub fn exec(state: *zlua.Lua) *Exec {
    var pointer: *Exec = undefined;
    @memcpy(std.mem.asBytes(&pointer), state.getExtraSpace()[0..@sizeOf(*Exec)]);
    return pointer;
}

fn hook(raw: ?*zlua.LuaState, _: HookDebug) callconv(.c) void {
    const state: *zlua.Lua = @ptrCast(raw.?);
    const value = exec(state);
    value.caller.io.checkCancel() catch |err| {
        value.caller.observe(err);
        state.raiseErrorStr("canceled", .{});
    };
    if (value.steps_left < 1000) state.raiseErrorStr("step limit exceeded", .{});
    value.steps_left -= 1000;
}

fn openCommon(state: *zlua.Lua, scope: Scope) void {
    state.openBase();
    state.openString();
    state.openTable();
    state.openMath();
    state.openUtf8();
    if (scope == .trusted) state.openCoroutine();
    inline for (.{ "collectgarbage", "dofile", "load", "loadfile", "print", "warn" }) |name| {
        state.pushNil();
        state.setGlobal(name);
    }
}

pub fn bytes(state: *zlua.Lua, index: i32) ![]const u8 {
    if (state.typeOf(index) != .string) return error.ExpectedBytes;
    return state.toString(index);
}

pub fn luaError(state: *zlua.Lua) anyerror {
    const caller = exec(state).caller;
    var canceled = caller.canceled.load(.acquire);
    if (!canceled and state.typeOf(-1) == .string) {
        canceled = std.mem.eql(u8, state.toString(-1) catch "", "Canceled");
        if (canceled) caller.canceled.store(true, .release);
    }
    if (state.getTop() > 0) state.pop(1);
    return if (canceled) error.Canceled else error.LuaFailure;
}

fn module(state: *zlua.Lua) !i32 {
    const value = exec(state);
    const name = try bytes(state, 1);
    if (value.scope == .eval and !std.mem.startsWith(u8, name, "public.")) return error.PrivateModule;
    const found = package.findModule(value.image, name) orelse return error.UnknownModule;
    try state.loadBuffer(found.bytecode, "module", .binary);
    state.protectedCall(.{ .results = 1 }) catch return luaError(state);
    return 1;
}

fn run(state: *zlua.Lua) !i32 {
    const value = exec(state);
    const input = if (state.getTop() >= 2) try bytes(state, 2) else "";
    if (state.typeOf(1) == .string) {
        var job = Job{ .source = try bytes(state, 1), .input = input };
        defer job.deinit(value.caller.allocator);
        try job.start(value);
        return switch (job.outcome) {
            .returned => |output| blk: {
                _ = state.pushString(output);
                break :blk 1;
            },
            .failed => |failure| failure,
            .pending => unreachable,
        };
    }
    if (state.typeOf(1) != .table) return error.ExpectedTable;
    const jobs = try value.caller.allocator.alloc(Job, state.lenRaw(1));
    defer value.caller.allocator.free(jobs);
    for (jobs) |*job| job.* = .{ .source = "", .input = input };
    defer for (jobs) |*job| job.deinit(value.caller.allocator);
    for (jobs, 1..) |*job, index| {
        _ = state.getIndex(1, @intCast(index));
        job.source = try bytes(state, -1);
        state.pop(1);
    }
    var group: std.Io.Group = .init;
    defer group.cancel(value.caller.io);
    for (jobs) |*job| group.async(value.caller.io, Job.start, .{ job, value });
    group.await(value.caller.io) catch |err| {
        value.caller.observe(err);
        return err;
    };
    for (jobs, 1..) |job, index| switch (job.outcome) {
        .failed => |failure| state.raiseErrorStr("eval %d failed: %s", .{ index, @errorName(failure).ptr }),
        .pending => unreachable,
        .returned => {},
    };
    state.createTable(@intCast(jobs.len), 0);
    for (jobs, 1..) |job, index| {
        _ = state.pushString(job.outcome.returned);
        state.setIndex(-2, @intCast(index));
    }
    return 1;
}

fn evalOne(job: *Job, parent: *const Exec) !void {
    var quota = Quota{ .child = parent.caller.allocator, .limit = parent.lua_bytes };
    var child_exec = Exec{
        .image = parent.image,
        .host = parent.host,
        .caller = parent.caller,
        .self = parent.self,
        .scope = .eval,
        .steps_left = parent.lua_steps,
        .lua_bytes = parent.lua_bytes,
        .lua_steps = parent.lua_steps,
    };
    const state = try zlua.Lua.init(quota.allocator());
    defer state.deinit();
    setExec(state, &child_exec);
    openCommon(state, .eval);
    try installCore(state);
    const source = try std.mem.concat(parent.caller.allocator, u8, &.{ "return function(input)\n", job.source, "\nend" });
    defer parent.caller.allocator.free(source);
    try state.loadBuffer(source, "eval", .text);
    state.protectedCall(.{ .results = 1 }) catch return luaError(state);
    _ = state.pushString(job.input);
    state.protectedCall(.{ .args = 1, .results = 1 }) catch return luaError(state);
    job.outcome = .{ .returned = try parent.caller.allocator.dupe(u8, try bytes(state, -1)) };
}

fn installCore(state: *zlua.Lua) !void {
    const value = exec(state);
    state.setHook(hook, .{ .count = true }, 1000);
    state.createTable(0, 8);
    state.pushFunction(zlua.wrap(module));
    state.setField(-2, "_module");
    state.pushFunction(zlua.wrap(Exec.luaCall));
    state.setField(-2, "_call");
    value.host.install(state, value.scope == .eval, value.caller);
    state.pushFunction(zlua.wrap(Exec.luaHandle));
    state.setField(-2, "handle");
    state.pushFunction(zlua.wrap(Exec.luaSelf));
    state.setField(-2, "self");
    if (value.scope == .trusted) {
        state.pushFunction(zlua.wrap(run));
        state.setField(-2, "run");
    }
    state.setGlobal("pa");
    try state.loadBuffer(
        \\local loaded,loading={},{}
        \\function pa._handle(bytes)
        \\ return {
        \\  id=function() return string.sub(bytes,1,32) end,
        \\  export=function() return bytes end,
        \\  call=function(input) return pa._call(bytes,input) end,
        \\ }
        \\end
        \\function pa.require(name)
        \\ local value=loaded[name]
        \\ if value~=nil then return value end
        \\ if loading[name] then error("cyclic module: "..name,0) end
        \\ loading[name]=true
        \\ local ok,result=pcall(pa._module,name)
        \\ loading[name]=nil
        \\ if not ok then error(result,0) end
        \\ if result==nil then error("module returned nil: "..name,0) end
        \\ loaded[name]=result
        \\ return result
        \\end
    , "core", .text);
    state.protectedCall(.{}) catch return luaError(state);
}

pub fn createTrusted(quota: *Quota, execution: *Exec) !*zlua.Lua {
    const state = try zlua.Lua.init(quota.allocator());
    errdefer state.deinit();
    setExec(state, execution);
    openCommon(state, .trusted);
    try installCore(state);
    return state;
}
