const std = @import("std");
const zlua = @import("zlua");
const runtime = @import("runtime.zig");

const Allocator = std.mem.Allocator;
pub const AgentId = [32]u8;

var marker: u8 = 0;

pub fn generateAgentId(io: std.Io) AgentId {
    var id: AgentId = undefined;
    io.random(&id);
    return id;
}

pub const Capability = struct {
    agent_id: AgentId,
    context: *anyopaque,
    invoke: *const fn (*anyopaque, Allocator, []const u8) anyerror![]u8,

    pub fn call(self: Capability, allocator: Allocator, input: []const u8) ![]u8 {
        return self.invoke(self.context, allocator, input);
    }
};

pub const Grant = struct {
    name: []const u8,
    capability: Capability,
};

pub const LuaCapability = struct {
    vm: *runtime.Vm,
    reference: i32,
    agent_id: AgentId,

    pub fn capture(vm: *runtime.Vm, index: i32) !LuaCapability {
        const agent_id = try capabilityAgentId(vm.lua, index);
        vm.lua.pushValue(index);
        return .{ .vm = vm, .reference = vm.lua.ref(zlua.registry_index), .agent_id = agent_id };
    }

    pub fn deinit(self: LuaCapability) void {
        self.vm.lua.unref(zlua.registry_index, self.reference);
    }

    pub fn capability(self: *LuaCapability) Capability {
        return .{ .agent_id = self.agent_id, .context = self, .invoke = invokeLua };
    }

    fn invokeLua(pointer: *anyopaque, allocator: Allocator, input: []const u8) ![]u8 {
        const self: *LuaCapability = @ptrCast(@alignCast(pointer));
        try self.vm.lua.checkStack(2);
        _ = self.vm.lua.getIndexRaw(zlua.registry_index, self.reference);
        _ = self.vm.lua.pushString(input);
        try self.vm.protect(.{ .args = 1, .results = 1 });
        defer self.vm.lua.pop(1);
        return allocator.dupe(u8, try runtime.bytes(self.vm.lua, -1));
    }
};

pub fn markCapability(lua: *zlua.Lua, metatable: i32, agent_id: AgentId) void {
    const table = lua.absIndex(metatable);
    _ = lua.pushString(&agent_id);
    lua.setPtrRaw(table, &marker);
}

pub fn capabilityAgentId(lua: *zlua.Lua, index: i32) !AgentId {
    lua.getMetatable(index) catch return error.ExpectedCapability;
    defer lua.pop(1);
    if (lua.getPtrRaw(-1, &marker) != .string) {
        lua.pop(1);
        return error.ExpectedCapability;
    }
    defer lua.pop(1);
    const value = try lua.toString(-1);
    if (value.len != @sizeOf(AgentId)) return error.ExpectedCapability;
    return value[0..@sizeOf(AgentId)].*;
}

pub fn pushMarkFunction(lua: *zlua.Lua, agent_id: *const AgentId) void {
    lua.pushLightUserdata(@constCast(agent_id));
    lua.pushClosure(zlua.wrap(mark), 1);
}

pub fn pushAgentIdFunction(lua: *zlua.Lua) void {
    lua.pushFunction(zlua.wrap(agentId));
}

pub fn pushCapabilityProxy(lua: *zlua.Lua, value: *const Capability) void {
    lua.createTable(0, 0);
    lua.createTable(0, 2);
    lua.pushLightUserdata(@constCast(value));
    lua.pushClosure(zlua.wrap(callProxy), 1);
    lua.setField(-2, "__call");
    lua.pushBoolean(false);
    lua.setField(-2, "__metatable");
    markCapability(lua, -1, value.agent_id);
    lua.setMetatable(-2);
}

fn mark(lua: *zlua.Lua) !i32 {
    const agent_id: *const AgentId = @ptrCast(@alignCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?));
    try lua.getMetatable(1);
    markCapability(lua, -1, agent_id.*);
    lua.pushValue(1);
    return 1;
}

fn agentId(lua: *zlua.Lua) !i32 {
    const value = try capabilityAgentId(lua, 1);
    _ = lua.pushString(&value);
    return 1;
}

fn callProxy(lua: *zlua.Lua) !i32 {
    const value: *const Capability = @ptrCast(@alignCast(@constCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?)));
    const output = try runtime.propagate(runtime.vm(lua).cancellation, value.call(lua.allocator(), try runtime.bytes(lua, 2)));
    defer lua.allocator().free(output);
    _ = lua.pushString(output);
    return 1;
}
