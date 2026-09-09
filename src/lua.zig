const std = @import("std");
const zlua = @import("zlua");
const package = @import("package.zig");
const identity = @import("identity.zig");
const host = @import("host.zig");

const Allocator = std.mem.Allocator;
const HookDebug = @typeInfo(@typeInfo(zlua.CHookFn).pointer.child).@"fn".params[1].type.?;

pub const Entry = struct {
    module: []const u8,
    members: []const []const u8 = &.{},
};

pub const Mount = struct {
    name: []const u8,
    context: *anyopaque,
    load: *const fn (*anyopaque, *zlua.Lua, i32) anyerror!void,
};

pub const Context = struct {
    agent: *anyopaque,
    call_agent: *const fn (*anyopaque, Allocator, Entry, []const u8) anyerror![]u8,
    quota: *Quota,
    client: *std.http.Client,
    image: *package.Image,
    entry: Entry,
    identity: *const identity.Identity,
    mounts: []const Mount,
    lua_steps: u64,
    steps_left: u64,
    canceled: *std.atomic.Value(bool),
};

pub const Quota = struct {
    child: Allocator,
    used: usize = 0,
    limit: usize,

    pub fn allocator(self: *Quota) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = Allocator.noResize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(pointer: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *Quota = @ptrCast(@alignCast(pointer));
        if (len > self.limit -| self.used) return null;
        const result = self.child.rawAlloc(len, alignment, address) orelse return null;
        self.used += len;
        return result;
    }

    fn remap(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, address: usize) ?[*]u8 {
        const self: *Quota = @ptrCast(@alignCast(pointer));
        if (new_len > memory.len and new_len - memory.len > self.limit -| self.used) return null;
        const result = self.child.rawRemap(memory, alignment, new_len, address) orelse return null;
        if (new_len > memory.len) self.used += new_len - memory.len else self.used -= memory.len - new_len;
        return result;
    }

    fn free(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *Quota = @ptrCast(@alignCast(pointer));
        self.child.rawFree(memory, alignment, address);
        self.used -= memory.len;
    }
};

const Job = struct {
    source: []const u8,
    input: []const u8,
    outcome: union(enum) { pending, returned: []u8, failed: anyerror } = .pending,

    fn start(self: *Job, parent: *const Context) std.Io.Cancelable!void {
        evalOne(self, parent) catch |err| {
            self.outcome = .{ .failed = err };
            if (err == error.Canceled) {
                parent.canceled.store(true, .release);
                return error.Canceled;
            }
        };
    }

    fn deinit(self: *Job, allocator: Allocator) void {
        switch (self.outcome) {
            .returned => |output| allocator.free(output),
            else => {},
        }
    }
};

pub fn call(context: *Context, input: []const u8) ![]u8 {
    const state = try open(context);
    defer state.deinit();
    try resolveEntry(state);
    _ = state.pushString(input);
    state.protectedCall(.{ .args = 1, .results = 1 }) catch return luaError(state);
    if (context.canceled.load(.acquire)) return error.Canceled;
    return context.quota.child.dupe(u8, try bytes(state, -1));
}

fn open(context: *Context) !*zlua.Lua {
    const state = try zlua.Lua.init(context.quota.allocator());
    errdefer state.deinit();
    setContext(state, context);
    state.openLibs();
    state.setHook(hook, .{ .count = true }, 1000);
    _ = state.getField(zlua.registry_index, zlua.preload_table);
    for (context.image.modules) |module| {
        try state.loadBuffer(module.bytecode, module.name, .binary);
        state.setField(-2, module.name);
    }
    state.pop(1);
    try installCore(state);
    return state;
}

fn installCore(state: *zlua.Lua) !void {
    const context = getContext(state);
    state.createTable(0, 6);
    state.pushFunction(zlua.wrap(markInterface));
    state.setField(-2, "_mark");
    state.pushLightUserdata(context);
    state.pushClosure(zlua.wrap(selfCall), 1);
    state.setField(-2, "_self");
    state.pushFunction(zlua.wrap(eval));
    state.setField(-2, "eval");
    try host.install(state, &context.client.io, context.client, context.canceled);
    state.setGlobal("pa");
    try state.loadBuffer(
        \\local mark,self=pa._mark,pa._self
        \\function pa.interface(call,modules)
        \\ if type(call)~="function" or modules~=nil and type(modules)~="table" then error("invalid interface",2) end
        \\ local interface={}
        \\ if modules then
        \\  for name,value in next,modules do
        \\   if type(name)~="string" then error("invalid interface module",2) end
        \\   interface[name]=value
        \\  end
        \\ end
        \\ return mark(setmetatable(interface,{__call=function(_,...) return call(...) end,__metatable=false}))
        \\end
        \\function pa.self() return pa.interface(self) end
        \\pa._mark,pa._self=nil,nil
    , "pa interface", .text);
    state.protectedCall(.{}) catch return luaError(state);
}

fn markInterface(state: *zlua.Lua) !i32 {
    state.getMetatable(1) catch unreachable;
    identity.mark(state, -1, getContext(state).identity.*);
    state.pushValue(1);
    return 1;
}

fn resolveEntry(state: *zlua.Lua) !void {
    const context = getContext(state);
    _ = state.getGlobal("require");
    _ = state.pushString(context.entry.module);
    state.protectedCall(.{ .args = 1, .results = 1 }) catch return luaError(state);
    for (context.entry.members) |member| {
        _ = state.pushString(member);
        _ = state.getTable(-2);
        state.remove(-2);
    }
    _ = try identity.read(state, -1);
}

fn selfCall(state: *zlua.Lua) !i32 {
    const context: *Context = @ptrCast(@alignCast(@constCast(state.toPointer(zlua.Lua.upvalueIndex(1)).?)));
    const output = context.call_agent(context.agent, state.allocator(), context.entry, try bytes(state, 1)) catch |err| {
        if (err == error.Canceled) context.canceled.store(true, .release);
        return err;
    };
    defer state.allocator().free(output);
    _ = state.pushString(output);
    return 1;
}

fn eval(state: *zlua.Lua) !i32 {
    const context = getContext(state);
    const input = if (state.getTop() >= 2) try bytes(state, 2) else "";
    if (state.typeOf(1) == .string) {
        var job = Job{ .source = try bytes(state, 1), .input = input };
        try evalOne(&job, context);
        defer context.quota.child.free(job.outcome.returned);
        _ = state.pushString(job.outcome.returned);
        return 1;
    }
    if (state.typeOf(1) != .table) return error.ExpectedEvalSource;
    const jobs = try context.quota.child.alloc(Job, state.lenRaw(1));
    defer context.quota.child.free(jobs);
    for (jobs) |*job| job.* = .{ .source = "", .input = input };
    defer for (jobs) |*job| job.deinit(context.quota.child);
    for (jobs, 1..) |*job, index| {
        _ = state.getIndex(1, @intCast(index));
        job.source = try bytes(state, -1);
        state.pop(1);
    }
    var group: std.Io.Group = .init;
    defer group.cancel(context.client.io);
    for (jobs) |*job| group.async(context.client.io, Job.start, .{ job, context });
    group.await(context.client.io) catch |err| {
        if (err == error.Canceled) context.canceled.store(true, .release);
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

fn evalOne(job: *Job, parent: *const Context) !void {
    var quota = Quota{ .child = parent.quota.child, .limit = parent.quota.limit };
    var context = parent.*;
    context.quota = &quota;
    context.steps_left = parent.lua_steps;
    const state = try open(&context);
    defer state.deinit();
    try resolveEntry(state);
    const environment = try publicEnvironment(state, -1);
    try state.loadBuffer(job.source, "eval", .text);
    state.pushValue(environment);
    _ = try state.setUpvalue(-2, 1);
    _ = state.pushString(job.input);
    state.protectedCall(.{ .args = 1, .results = 1 }) catch return luaError(state);
    if (context.canceled.load(.acquire)) return error.Canceled;
    job.outcome = .{ .returned = try parent.quota.child.dupe(u8, try bytes(state, -1)) };
}

fn publicEnvironment(state: *zlua.Lua, interface: i32) !i32 {
    const interface_index = state.absIndex(interface);
    state.createTable(0, @intCast(getContext(state).mounts.len));
    const preload = state.absIndex(-1);
    try state.loadBuffer(
        \\local base={"assert","error","ipairs","next","pairs","rawequal","rawget","rawlen","rawset","select","getmetatable","setmetatable","tonumber","tostring","type","_VERSION"}
        \\local libraries={"math","string","table","utf8"}
        \\local pcall,error,tostring=pcall,error,tostring
        \\local function clone(source) local target={} for key,value in pairs(source) do target[key]=value end return target end
        \\return function(interface,preload)
        \\ for name,value in pairs(interface) do
        \\  if preload[name]~=nil then error("duplicate eval module: "..name,0) end
        \\  preload[name]=function() return value end
        \\ end
        \\ local env={} for _,name in ipairs(base) do env[name]=_G[name] end
        \\ for _,name in ipairs(libraries) do env[name]=clone(_G[name]) end
        \\ local package={preload=preload,loaded={}} env.package=package env._G=env
        \\ local loading={}
        \\ env.require=function(name)
        \\  local value=package.loaded[name] if value~=nil then return value end
        \\  local loader=package.preload[name] if loader==nil then error("module not found: "..tostring(name),0) end
        \\  if loading[name] then error("cyclic module: "..tostring(name),0) end loading[name]=true
        \\  local ok,result=pcall(loader,name) loading[name]=nil if not ok then error(result,0) end
        \\  if result~=nil then package.loaded[name]=result end if package.loaded[name]==nil then package.loaded[name]=true end
        \\  return package.loaded[name]
        \\ end
        \\ return env
        \\end
    , "public environment", .text);
    state.protectedCall(.{ .results = 1 }) catch return luaError(state);
    state.pushValue(interface_index);
    state.pushValue(preload);
    state.protectedCall(.{ .args = 2, .results = 1 }) catch return luaError(state);
    const environment = state.absIndex(-1);
    for (getContext(state).mounts) |*mount| {
        _ = state.pushString(mount.name);
        if (state.getTableRaw(preload) != .nil) return error.DuplicateEvalModule;
        state.pop(1);
        _ = state.pushString(mount.name);
        state.pushLightUserdata(mount);
        state.pushValue(environment);
        state.pushClosure(zlua.wrap(loadMount), 2);
        state.setTableRaw(preload);
    }
    state.remove(preload);
    return state.absIndex(-1);
}

fn loadMount(state: *zlua.Lua) !i32 {
    const mount: *const Mount = @ptrCast(@alignCast(state.toPointer(zlua.Lua.upvalueIndex(1)).?));
    const top = state.getTop();
    mount.load(mount.context, state, zlua.Lua.upvalueIndex(2)) catch |err| {
        if (err == error.Canceled) getContext(state).canceled.store(true, .release);
        return err;
    };
    if (state.getTop() != top + 1) return error.InvalidMountLoader;
    return 1;
}

fn bytes(state: *zlua.Lua, index: i32) ![]const u8 {
    return if (state.typeOf(index) == .string) state.toString(index) else error.ExpectedBytes;
}

fn luaError(state: *zlua.Lua) anyerror {
    if (state.getTop() > 0) state.pop(1);
    return if (getContext(state).canceled.load(.acquire)) error.Canceled else error.LuaFailure;
}

fn hook(raw: ?*zlua.LuaState, _: HookDebug) callconv(.c) void {
    const state: *zlua.Lua = @ptrCast(raw.?);
    const context = getContext(state);
    context.client.io.checkCancel() catch {
        context.canceled.store(true, .release);
        state.raiseErrorStr("canceled", .{});
    };
    if (context.steps_left < 1000) state.raiseErrorStr("step limit exceeded", .{});
    context.steps_left -= 1000;
}

fn setContext(state: *zlua.Lua, context: *Context) void {
    @as(**Context, @ptrCast(@alignCast(state.getExtraSpace().ptr))).* = context;
}

fn getContext(state: *zlua.Lua) *Context {
    return @as(**Context, @ptrCast(@alignCast(state.getExtraSpace().ptr))).*;
}
