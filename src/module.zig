const std = @import("std");
const zlua = @import("zlua");
const lua_state = @import("lua.zig");

pub const Resolved = struct {
    state: *zlua.Lua,
    root: i32,
    members: i32,

    pub fn capture(lua: *zlua.Lua, index: i32) !Resolved {
        const top = lua.getTop();
        defer lua.setTop(top);
        if (!lua.isTable(index)) return error.ExpectedModule;
        if (lua.getMetaField(index, "__call") != .function) return error.ExpectedCallableModule;
        lua.pop(1);
        const table = lua.absIndex(index);
        lua.createTable(0, 0);
        const members = lua.absIndex(-1);
        lua.pushNil();
        while (lua.next(table)) {
            if (lua.typeOf(-2) != .string or !lua.isFunction(-1)) return error.InvalidModuleMember;
            lua.pushValue(-2);
            lua.pushValue(-2);
            lua.setTableRaw(members);
            lua.pop(1);
        }
        lua.pushValue(table);
        const root = lua.ref(zlua.registry_index);
        lua.pushValue(members);
        return .{ .state = lua, .root = root, .members = lua.ref(zlua.registry_index) };
    }

    pub fn deinit(self: Resolved) void {
        self.state.unref(zlua.registry_index, self.root);
        self.state.unref(zlua.registry_index, self.members);
    }

    pub fn call(self: Resolved, allocator: std.mem.Allocator, input: []const u8, config: []const u8, member: ?[]const u8) ![]u8 {
        const lua = self.state;
        const top = lua.getTop();
        defer lua.setTop(top);
        _ = lua.getIndexRaw(zlua.registry_index, if (member != null) self.members else self.root);
        if (member) |name| {
            _ = lua.pushString(name);
            _ = lua.getTableRaw(-2);
            lua.remove(-2);
            if (!lua.isFunction(-1)) return error.UnknownMember;
        }
        _ = lua.pushString(input);
        _ = lua.pushString(config);
        try lua_state.protect(lua, .{ .args = 2, .results = 1 });
        return allocator.dupe(u8, try lua_state.bytes(lua, -1));
    }

    pub fn select(self: Resolved, index: i32, name: []const u8) bool {
        const lua = self.state;
        const value = lua.absIndex(index);
        _ = lua.getIndexRaw(zlua.registry_index, self.members);
        _ = lua.pushString(name);
        _ = lua.getTableRaw(-2);
        const matches = lua.equalRaw(value, -1);
        lua.pop(2);
        return matches;
    }
};

pub fn pushModuleProxy(lua: *zlua.Lua, value: *const Resolved, config: *const []const u8) void {
    const source = value.state;
    const top = source.getTop();
    defer source.setTop(top);
    _ = source.getIndexRaw(zlua.registry_index, value.members);
    const members = source.absIndex(-1);
    lua.createTable(0, 0);
    source.pushNil();
    while (source.next(members)) {
        const name = source.toString(-2) catch unreachable;
        _ = lua.pushString(name);
        pushNativeProxy(lua, value, config, name, true);
        lua.setTableRaw(-3);
        source.pop(1);
    }
    lua.createTable(0, 3);
    pushNativeProxy(lua, value, config, null, true);
    lua.setField(-2, "__call");
    _ = source.getIndexRaw(zlua.registry_index, value.root);
    if (source.getMetaField(-1, "__tostring") == .function) {
        lua.pushLightUserdata(value);
        lua.pushClosure(zlua.wrap(stringifyProxy), 1);
        lua.setField(-2, "__tostring");
    }
    lua.pushBoolean(false);
    lua.setField(-2, "__metatable");
    lua.setMetatable(-2);
}

pub fn pushLoader(lua: *zlua.Lua, value: *const Resolved, config: *const []const u8) void {
    lua.pushLightUserdata(value);
    lua.pushLightUserdata(@ptrCast(config));
    lua.pushClosure(zlua.wrap(loadProxy), 2);
}

pub fn pushNativeProxy(lua: *zlua.Lua, value: *const Resolved, config: *const []const u8, name: ?[]const u8, prepend_config: bool) void {
    lua.pushLightUserdata(value);
    lua.pushLightUserdata(@ptrCast(config));
    if (name) |member| _ = lua.pushString(member) else lua.pushNil();
    lua.pushBoolean(prepend_config);
    lua.pushClosure(zlua.wrap(callProxy), 4);
}

fn loadProxy(lua: *zlua.Lua) i32 {
    const value: *const Resolved = @ptrCast(@alignCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?));
    const config: *const []const u8 = @ptrCast(@alignCast(lua.toPointer(zlua.Lua.upvalueIndex(2)).?));
    pushModuleProxy(lua, value, config);
    return 1;
}

fn stringifyProxy(lua: *zlua.Lua) !i32 {
    const value: *const Resolved = @ptrCast(@alignCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?));
    const source = value.state;
    const top = source.getTop();
    defer source.setTop(top);
    _ = source.getIndexRaw(zlua.registry_index, value.root);
    if (source.getMetaField(-1, "__tostring") != .function) return error.InvalidModuleDescription;
    source.insert(-2);
    const result = lua_state.protect(source, .{ .args = 1, .results = 1 });
    if (lua_state.control(source).cancellation.canceled()) {
        lua_state.control(lua).cancellation.cancel();
        return error.Canceled;
    }
    if (lua_state.control(source).instruction_exhausted) {
        lua_state.control(lua).instruction_exhausted = true;
        return error.InstructionLimit;
    }
    try result;
    _ = lua.pushString(try lua_state.bytes(source, -1));
    return 1;
}

fn callProxy(lua: *zlua.Lua) !i32 {
    const value: *const Resolved = @ptrCast(@alignCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?));
    const config: *const []const u8 = @ptrCast(@alignCast(lua.toPointer(zlua.Lua.upvalueIndex(2)).?));
    if (lua.isNil(zlua.Lua.upvalueIndex(3))) {
        const output = value.call(lua.allocator(), try lua_state.bytes(lua, 2), config.*, null) catch |err| {
            if (err == error.Canceled) lua_state.control(lua).cancellation.cancel();
            if (err == error.InstructionLimit) lua_state.control(lua).instruction_exhausted = true;
            return err;
        };
        defer lua.allocator().free(output);
        _ = lua.pushString(output);
        return 1;
    }
    const target = value.state;
    const arguments = lua.getTop();
    const top = target.getTop();
    defer target.setTop(top);
    target.pushFunction(zlua.wrap(lua_state.traceback));
    const message_handler = target.getTop();
    _ = target.getIndexRaw(zlua.registry_index, value.members);
    _ = target.pushString(try lua_state.bytes(lua, zlua.Lua.upvalueIndex(3)));
    _ = target.getTableRaw(-2);
    target.remove(-2);
    const prepend_config = lua.toBoolean(zlua.Lua.upvalueIndex(4));
    if (prepend_config) _ = target.pushString(config.*);
    for (1..@as(usize, @intCast(arguments)) + 1) |index| try lua_state.transfer(lua, target, @intCast(index), 0);
    if (!prepend_config) _ = target.pushString(config.*);
    target.protectedCall(.{ .args = arguments + 1, .results = 1, .msg_handler = message_handler }) catch {
        if (lua_state.control(target).cancellation.canceled()) return error.Canceled;
        if (lua_state.control(target).instruction_exhausted) {
            lua_state.control(lua).instruction_exhausted = true;
            return error.InstructionLimit;
        }
        _ = lua.pushString(target.toString(-1) catch "LuaFailure");
        lua.raiseError();
    };
    try lua_state.transfer(target, lua, -1, 0);
    return 1;
}
