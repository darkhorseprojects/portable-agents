const std = @import("std");
const zlua = @import("zlua");
const package = @import("package.zig");
const identity = @import("identity.zig");
const host = @import("host.zig");

const Allocator = std.mem.Allocator;

pub const Entry = struct {
    module: []const u8,
    members: []const []const u8 = &.{},
};

pub const Interface = struct {
    identity: identity.Identity,
    context: *anyopaque,
    call: *const fn (*anyopaque, Allocator, []const u8) anyerror![]u8,
};

pub const Mount = struct {
    name: []const u8,
    interface: Interface,
};

pub const Context = struct {
    self: Interface,
    quota: *Quota,
    client: *std.http.Client,
    image: *const package.Image,
    entry: Entry,
    mounts: []const Mount,
    lua_steps: u64,
    steps_left: u64,
    canceled: *std.atomic.Value(bool),
    input: []const u8 = "",
    source: ?[]const u8 = null,
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

pub fn call(context: *Context, input: []const u8) ![]u8 {
    context.input = input;
    return executeState(context);
}

fn initialize(state: *zlua.Lua) !i32 {
    const context = getContext(state);
    state.openLibs();
    state.setHook(zlua.wrap(hook), .{ .count = true }, 1000);
    _ = state.getField(zlua.registry_index, zlua.preload_table);
    for (context.image.modules) |module| {
        try state.loadBuffer(module.bytecode, module.name, .binary);
        state.setField(-2, module.name);
    }
    state.pop(1);
    state.createTable(0, 8);
    state.pushFunction(zlua.wrap(markInterface));
    state.setField(-2, "_mark");
    state.pushFunction(zlua.wrap(selfCall));
    state.setField(-2, "_self");
    state.pushFunction(zlua.wrap(interfaceIdentity));
    state.setField(-2, "_identity");
    state.pushFunction(zlua.wrap(eval));
    state.setField(-2, "eval");
    try host.install(state, &context.client.io, context.client, context.canceled);
    state.setGlobal("pa");
    try state.loadBuffer(
        \\local mark,self,identity,private_require=pa._mark,pa._self,pa._identity,require
        \\local next,type,error,select,ipairs,pcall,tostring,setmetatable,settypemt=next,type,error,select,ipairs,pcall,tostring,setmetatable,debug.setmetatable
        \\local function clone(source) local target={} for key,value in next,source do target[key]=value end return target end
        \\local base={assert=assert,error=error,ipairs=ipairs,next=next,pairs=pairs,rawequal=rawequal,rawget=rawget,rawlen=rawlen,rawset=rawset,select=select,setmetatable=setmetatable,tonumber=tonumber,tostring=tostring,type=type,_VERSION=_VERSION}
        \\local libraries={math=clone(math),string=clone(string),table=clone(table),utf8=clone(utf8)} libraries.string.dump,libraries.string.__index=nil,nil
        \\function pa._resolve(module,...) local value=private_require(module) for index=1,select("#",...) do value=value[select(index,...)] end return value end
        \\function pa.interface(call,modules)
        \\ if type(call)~="function" or modules~=nil and type(modules)~="table" then error("invalid interface",2) end
        \\ local interface=clone(modules or {}) for name in next,interface do if type(name)~="string" then error("invalid interface module",2) end end
        \\ return mark(setmetatable(interface,{__call=function(_,...) return call(...) end,__metatable=false})) end
        \\function pa.self() return pa.interface(self) end pa.identity=identity
        \\function pa._public(interface,mounts) local preload={}
        \\ for _,values in ipairs({interface,mounts}) do
        \\  for name,value in next,values do
        \\   if preload[name]~=nil then error("duplicate eval module: "..name,0) end preload[name]=function() return value end
        \\  end end
        \\ local env=clone(base) env.identity=identity for name,value in next,libraries do env[name]=clone(value) end
        \\ env.string.__index=env.string env.string.__metatable=false settypemt("",env.string)
        \\ local package={preload=preload,loaded={}} local loading={} env.package=package env._G=env
        \\ env.require=function(name)
        \\  local value=package.loaded[name] if value~=nil then return value end
        \\  local loader=package.preload[name] if loader==nil then error("module not found: "..tostring(name),0) end if loading[name] then error("cyclic module: "..tostring(name),0) end loading[name]=true
        \\  local ok,result=pcall(loader,name) loading[name]=nil if not ok then error(result,0) end
        \\  if result~=nil then package.loaded[name]=result end if package.loaded[name]==nil then package.loaded[name]=true end
        \\  return package.loaded[name] end
        \\ return env end
        \\pa._mark,pa._self,pa._identity=nil,nil,nil
    , "pa", .text);
    state.call(.{});
    return 0;
}

fn markInterface(state: *zlua.Lua) !i32 {
    try state.getMetatable(1);
    identity.mark(state, -1, getContext(state).self.identity);
    state.pushValue(1);
    return 1;
}

fn interfaceIdentity(state: *zlua.Lua) !i32 {
    const value = try identity.read(state, 1);
    _ = state.pushString(&value);
    return 1;
}

fn selfCall(state: *zlua.Lua) !i32 {
    return invoke(state, &getContext(state).self, 1);
}

fn eval(state: *zlua.Lua) !i32 {
    const context = getContext(state);
    const input = if (state.getTop() >= 2) try bytes(state, 2) else "";
    if (state.typeOf(1) == .string) {
        const output = try evalOne(context, try bytes(state, 1), input);
        defer context.quota.child.free(output);
        _ = state.pushString(output);
        return 1;
    }
    if (state.typeOf(1) != .table) return error.ExpectedEvalSource;
    const count = state.lenRaw(1);
    for (1..count + 1) |index| {
        _ = state.getIndex(1, @intCast(index));
        _ = try bytes(state, -1);
        state.pop(1);
    }
    const futures = try context.quota.child.alloc(std.Io.Future(anyerror![]u8), count);
    defer context.quota.child.free(futures);
    for (futures, 1..) |*future, index| {
        _ = state.getIndex(1, @intCast(index));
        const source = bytes(state, -1) catch unreachable;
        future.* = context.client.io.async(evalOne, .{ context, source, input });
        state.pop(1);
    }
    for (futures) |*future| {
        if (if (context.canceled.load(.acquire)) future.cancel(context.client.io) else future.await(context.client.io)) |_| {} else |err| {
            if (err == error.Canceled) context.canceled.store(true, .release);
        }
    }
    defer for (futures) |future| if (future.result) |output| context.quota.child.free(output) else |_| {};
    state.createTable(@intCast(count), 0);
    for (futures, 1..) |future, index| {
        _ = state.pushString(try future.result);
        state.setIndex(-2, @intCast(index));
    }
    return 1;
}

fn evalOne(parent: *const Context, source: []const u8, input: []const u8) anyerror![]u8 {
    var quota = Quota{ .child = parent.quota.child, .limit = parent.quota.limit };
    var context = parent.*;
    context.quota = &quota;
    context.steps_left = parent.lua_steps;
    context.input = input;
    context.source = source;
    return executeState(&context);
}

fn pushInterface(state: *zlua.Lua, interface: *const Interface) void {
    state.createTable(0, 0);
    state.createTable(0, 2);
    state.pushLightUserdata(@constCast(interface));
    state.pushClosure(zlua.wrap(callInterface), 1);
    state.setField(-2, "__call");
    state.pushBoolean(false);
    state.setField(-2, "__metatable");
    identity.mark(state, -1, interface.identity);
    state.setMetatable(-2);
}

fn callInterface(state: *zlua.Lua) !i32 {
    const interface: *const Interface = @ptrCast(@alignCast(@constCast(state.toPointer(zlua.Lua.upvalueIndex(1)).?)));
    return invoke(state, interface, 2);
}

fn invoke(state: *zlua.Lua, interface: *const Interface, input: i32) !i32 {
    const output = interface.call(interface.context, state.allocator(), try bytes(state, input)) catch |err| {
        if (err == error.Canceled) getContext(state).canceled.store(true, .release);
        return err;
    };
    defer state.allocator().free(output);
    _ = state.pushString(output);
    return 1;
}

fn bytes(state: *zlua.Lua, index: i32) ![]const u8 {
    return if (state.typeOf(index) == .string) state.toString(index) else error.ExpectedBytes;
}

fn executeState(context: *Context) ![]u8 {
    const state = try zlua.Lua.init(context.quota.allocator());
    defer state.deinit();
    @as(**Context, @ptrCast(@alignCast(state.getExtraSpace().ptr))).* = context;
    state.pushFunction(zlua.wrap(initialize));
    state.protectedCall(.{}) catch return if (context.canceled.load(.acquire)) error.Canceled else error.LuaFailure;
    state.pushFunction(zlua.wrap(execute));
    state.protectedCall(.{ .results = 1 }) catch return if (context.canceled.load(.acquire)) error.Canceled else error.LuaFailure;
    if (context.canceled.load(.acquire)) return error.Canceled;
    return context.quota.child.dupe(u8, try bytes(state, -1));
}

fn execute(state: *zlua.Lua) !i32 {
    const context = getContext(state);
    _ = state.getGlobal("pa");
    _ = state.getField(-1, "_resolve");
    state.remove(-2);
    _ = state.pushString(context.entry.module);
    for (context.entry.members) |member| _ = state.pushString(member);
    const args = std.math.cast(i32, try std.math.add(usize, context.entry.members.len, 1)) orelse return error.TooManyMembers;
    state.call(.{ .args = args, .results = 1 });
    _ = try identity.read(state, -1);
    if (context.source) |source| {
        const interface = state.absIndex(-1);
        state.createTable(0, @intCast(context.mounts.len));
        const mounts = state.absIndex(-1);
        for (context.mounts) |*mount| {
            _ = state.pushString(mount.name);
            pushInterface(state, &mount.interface);
            state.setTableRaw(mounts);
        }
        _ = state.getGlobal("pa");
        _ = state.getField(-1, "_public");
        state.remove(-2);
        state.pushValue(interface);
        state.pushValue(mounts);
        state.call(.{ .args = 2, .results = 1 });
        state.remove(mounts);
        try state.loadBuffer(source, "eval", .text);
        state.pushValue(-2);
        _ = try state.setUpvalue(-2, 1);
    }
    _ = state.pushString(context.input);
    state.call(.{ .args = 1, .results = 1 });
    return 1;
}

fn hook(state: *zlua.Lua, _: zlua.Event, _: *zlua.DebugInfo) void {
    const context = getContext(state);
    context.client.io.checkCancel() catch {
        context.canceled.store(true, .release);
        state.raiseErrorStr("canceled", .{});
    };
    if (context.steps_left < 1000) state.raiseErrorStr("step limit exceeded", .{});
    context.steps_left -= 1000;
}

fn getContext(state: *zlua.Lua) *Context {
    return @as(**Context, @ptrCast(@alignCast(state.getExtraSpace().ptr))).*;
}
