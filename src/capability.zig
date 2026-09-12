const std = @import("std");
const zlua = @import("zlua");
const lua_state = @import("lua.zig");

const Allocator = std.mem.Allocator;
pub const AgentId = [32]u8;

var marker: u8 = 0;

pub fn generateAgentId(io: std.Io) AgentId {
    var id: AgentId = undefined;
    io.random(&id);
    return id;
}

pub const Resolved = struct {
    lua: *zlua.Lua,
    reference: i32,
    agent_id: AgentId,

    pub fn capture(lua: *zlua.Lua, index: i32) !Resolved {
        const agent_id = try capabilityAgentId(lua, index);
        lua.pushValue(index);
        return .{ .lua = lua, .reference = lua.ref(zlua.registry_index), .agent_id = agent_id };
    }

    pub fn deinit(self: Resolved) void {
        self.lua.unref(zlua.registry_index, self.reference);
    }

    pub fn call(self: Resolved, allocator: Allocator, input: []const u8) ![]u8 {
        try self.lua.checkStack(2);
        _ = self.lua.getIndexRaw(zlua.registry_index, self.reference);
        _ = self.lua.pushString(input);
        try lua_state.protect(self.lua, .{ .args = 1, .results = 1 });
        defer self.lua.pop(1);
        return allocator.dupe(u8, try lua_state.bytes(self.lua, -1));
    }
};

pub const Export = struct {
    name: []const u8,
    value: Resolved,
};

pub fn captureExports(allocator: Allocator, root: Resolved) ![]Export {
    var values: std.ArrayList(Export) = .empty;
    errdefer {
        for (values.items) |value| value.value.deinit();
        values.deinit(allocator);
    }
    const top = root.lua.getTop();
    defer root.lua.setTop(top);
    _ = root.lua.getIndexRaw(zlua.registry_index, root.reference);
    root.lua.pushNil();
    while (root.lua.next(-2)) {
        if (root.lua.typeOf(-2) != .string) return error.InvalidCapabilityExport;
        const value = try Resolved.capture(root.lua, -1);
        values.append(allocator, .{ .name = try root.lua.toString(-2), .value = value }) catch |err| {
            value.deinit();
            return err;
        };
        root.lua.pop(1);
    }
    return values.toOwnedSlice(allocator);
}

pub fn freeExports(allocator: Allocator, values: []Export) void {
    for (values) |value| value.value.deinit();
    allocator.free(values);
}

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

pub fn pushProxy(lua: *zlua.Lua, value: *const Resolved) void {
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

pub fn pushLoader(lua: *zlua.Lua, value: *const Resolved) void {
    lua.pushLightUserdata(@constCast(value));
    lua.pushClosure(zlua.wrap(loadProxy), 1);
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

fn loadProxy(lua: *zlua.Lua) i32 {
    const value: *const Resolved = @ptrCast(@alignCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?));
    pushProxy(lua, value);
    return 1;
}

fn callProxy(lua: *zlua.Lua) !i32 {
    const value: *const Resolved = @ptrCast(@alignCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?));
    const cancellation = lua_state.control(lua).cancellation;
    const output = try lua_state.propagate(cancellation, value.call(lua.allocator(), try lua_state.bytes(lua, 2)));
    defer lua.allocator().free(output);
    _ = lua.pushString(output);
    return 1;
}
