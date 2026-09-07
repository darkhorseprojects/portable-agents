const std = @import("std");
const zlua = @import("zlua");
const package = @import("package.zig");
const host = @import("host.zig");
const identity = @import("identity.zig");

const Allocator = std.mem.Allocator;
const HookDebug = @typeInfo(@typeInfo(zlua.CHookFn).pointer.child).@"fn".params[1].type.?;

pub const Scope = enum { trusted, eval };

pub const Exec = struct {
    image: *const package.Image,
    host: *host.Host,
    caller: *identity.Caller,
    allocator: Allocator,
    io: std.Io,
    scope: Scope,
    steps_left: u64,
    lua_bytes: usize,
    lua_steps: u64,
    self: identity.Handle,
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
    arena: std.heap.ArenaAllocator,
    outcome: union(enum) { pending, returned: []const u8, failed: anyerror } = .pending,
};

pub fn setExec(state: *zlua.Lua, value: *Exec) void {
    const space = state.getExtraSpace();
    const pointer: *Exec = value;
    @memcpy(space[0..@sizeOf(*Exec)], std.mem.asBytes(&pointer));
}

pub fn exec(state: *zlua.Lua) *Exec {
    var pointer: *Exec = undefined;
    @memcpy(std.mem.asBytes(&pointer), state.getExtraSpace()[0..@sizeOf(*Exec)]);
    return pointer;
}

fn hook(raw: ?*zlua.LuaState, _: HookDebug) callconv(.c) void {
    const state: *zlua.Lua = @ptrCast(raw.?);
    const value = exec(state);
    if (value.io.checkCancel()) |_| {} else |_| state.raiseErrorStr("canceled", .{});
    if (value.steps_left <= 1000) state.raiseErrorStr("step limit exceeded", .{});
    value.steps_left -= 1000;
}

fn openCommon(state: *zlua.Lua) void {
    state.openBase();
    state.openString();
    state.openTable();
    state.openMath();
    state.openUtf8();
    inline for (.{ "collectgarbage", "dofile", "load", "loadfile", "print", "warn" }) |name| {
        state.pushNil();
        state.setGlobal(name);
    }
}

fn openTrusted(state: *zlua.Lua) void {
    openCommon(state);
    state.openCoroutine();
}

fn openEval(state: *zlua.Lua) void {
    openCommon(state);
}

pub fn bytes(state: *zlua.Lua, index: i32) ![]const u8 {
    if (state.typeOf(index) != .string) return error.ExpectedBytes;
    return state.toString(index);
}

fn denseSources(state: *zlua.Lua, allocator: Allocator, index: i32) ![]const []const u8 {
    if (state.typeOf(index) != .table) return error.ExpectedTable;
    const count = state.lenRaw(index);
    const sources = try allocator.alloc([]const u8, count);
    errdefer allocator.free(sources);
    for (sources, 0..) |*source, offset| {
        _ = state.getIndex(index, @intCast(offset + 1));
        source.* = try bytes(state, -1);
        state.pop(1);
    }
    return sources;
}

pub fn luaError(state: *zlua.Lua) anyerror {
    if (state.getTop() > 0) state.pop(1);
    return error.LuaFailure;
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
        var job = Job{ .source = try bytes(state, 1), .input = input, .arena = .init(value.allocator) };
        defer job.arena.deinit();
        evalOne(&job, value);
        return switch (job.outcome) {
            .returned => |output| blk: {
                _ = state.pushString(output);
                break :blk 1;
            },
            .failed => |failure| failure,
            .pending => unreachable,
        };
    }
    const sources = try denseSources(state, value.allocator, 1);
    defer value.allocator.free(sources);
    const jobs = try value.allocator.alloc(Job, sources.len);
    defer value.allocator.free(jobs);
    for (sources, jobs) |source, *job| job.* = .{ .source = source, .input = input, .arena = .init(value.allocator) };
    defer for (jobs) |*job| job.arena.deinit();
    var group: std.Io.Group = .init;
    defer group.cancel(value.io);
    const Task = struct {
        fn start(job: *Job, parent: *const Exec) std.Io.Cancelable!void {
            evalOne(job, parent);
        }
    };
    for (jobs) |*job| group.async(value.io, Task.start, .{ job, value });
    try group.await(value.io);
    for (jobs, 0..) |job, index| switch (job.outcome) {
        .failed => |failure| state.raiseErrorStr("eval %d failed: %s", .{ index + 1, @errorName(failure).ptr }),
        .pending => unreachable,
        .returned => {},
    };
    state.createTable(@intCast(jobs.len), 0);
    for (jobs, 0..) |job, index| {
        _ = state.pushString(job.outcome.returned);
        state.setIndex(-2, @intCast(index + 1));
    }
    return 1;
}

fn evalOne(job: *Job, parent: *const Exec) void {
    var quota = Quota{ .child = parent.allocator, .limit = parent.lua_bytes };
    var child_exec = Exec{
        .image = parent.image,
        .host = parent.host,
        .caller = parent.caller,
        .allocator = parent.allocator,
        .io = parent.io,
        .scope = .eval,
        .steps_left = parent.lua_steps,
        .lua_bytes = parent.lua_bytes,
        .lua_steps = parent.lua_steps,
        .self = parent.self,
    };
    const state = zlua.Lua.init(quota.allocator()) catch |failure| {
        job.outcome = .{ .failed = failure };
        return;
    };
    defer state.deinit();
    setExec(state, &child_exec);
    openEval(state);
    installCore(state) catch |failure| {
        job.outcome = .{ .failed = failure };
        return;
    };
    const source = std.mem.concat(job.arena.allocator(), u8, &.{ "return function(input)\n", job.source, "\nend" }) catch |failure| {
        job.outcome = .{ .failed = failure };
        return;
    };
    state.loadBuffer(source, "eval", .text) catch |failure| {
        job.outcome = .{ .failed = failure };
        return;
    };
    state.protectedCall(.{ .results = 1 }) catch |failure| {
        job.outcome = .{ .failed = failure };
        return;
    };
    _ = state.pushString(job.input);
    state.protectedCall(.{ .args = 1, .results = 1 }) catch |failure| {
        job.outcome = .{ .failed = failure };
        return;
    };
    const output = bytes(state, -1) catch |failure| {
        job.outcome = .{ .failed = failure };
        return;
    };
    job.outcome = .{ .returned = job.arena.allocator().dupe(u8, output) catch |failure| {
        job.outcome = .{ .failed = failure };
        return;
    } };
}

fn installCore(state: *zlua.Lua) !void {
    const value = exec(state);
    state.setHook(hook, .{ .count = true }, 1000);
    state.createTable(0, 8);
    state.pushFunction(zlua.wrap(module));
    state.setField(-2, "_module");
    value.host.install(state, value.scope == .eval, value.caller);
    const Callbacks = struct {
        fn handleValue(lua: *zlua.Lua) !i32 {
            const context = exec(lua);
            const imported = try identity.decodeHandle(context.allocator, try bytes(lua, 1));
            defer context.allocator.free(imported.route);
            try identity.pushHandle(lua, imported, context.caller);
            return 1;
        }
        fn selfValue(lua: *zlua.Lua) !i32 {
            const context = exec(lua);
            try identity.pushHandle(lua, context.self, context.caller);
            return 1;
        }
    };
    state.pushFunction(zlua.wrap(Callbacks.handleValue));
    state.setField(-2, "handle");
    state.pushFunction(zlua.wrap(Callbacks.selfValue));
    state.setField(-2, "self");
    if (value.scope == .trusted) {
        state.pushFunction(zlua.wrap(run));
        state.setField(-2, "run");
    }
    state.setGlobal("pa");
    try state.loadBuffer(
        \\local loaded,loading={},{}
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
    openTrusted(state);
    try installCore(state);
    return state;
}
