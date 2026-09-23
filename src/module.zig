const std = @import("std");
const zlua = @import("zlua");
const lua_state = @import("lua.zig");

const Allocator = std.mem.Allocator;

pub const Callable = struct {
    state: *zlua.Lua,
    reference: i32,

    fn capture(state: *zlua.Lua, index: i32) Callable {
        state.pushValue(index);
        return .{ .state = state, .reference = state.ref(zlua.registry_index) };
    }

    fn deinit(self: Callable) void {
        self.state.unref(zlua.registry_index, self.reference);
    }

    pub fn call(self: Callable, allocator: Allocator, input: []const u8, config: []const u8) ![]u8 {
        self.state.pushFunction(zlua.wrap(invoke));
        self.state.pushLightUserdata(&self);
        self.state.pushLightUserdata(@ptrCast(&input));
        self.state.pushLightUserdata(@ptrCast(&config));
        try lua_state.protect(self.state, .{ .args = 3, .results = 1 });
        defer self.state.pop(1);
        return allocator.dupe(u8, try lua_state.bytes(self.state, -1));
    }
};

pub const Member = struct {
    name: []const u8,
    callable: Callable,
};

pub const Resolved = struct {
    callable: Callable,
    members: []Member,

    pub fn capture(allocator: Allocator, lua: *zlua.Lua, index: i32) !Resolved {
        if (!lua.isTable(index)) return error.ExpectedModule;
        if (lua.getMetaField(index, "__call") != .function) return error.ExpectedCallableModule;
        lua.pop(1);
        var members: std.ArrayList(Member) = .empty;
        errdefer {
            for (members.items) |member_value| member_value.callable.deinit();
            members.deinit(allocator);
        }
        const table = lua.absIndex(index);
        lua.pushNil();
        while (lua.next(table)) {
            if (lua.typeOf(-2) != .string or !lua.isFunction(-1)) return error.InvalidModuleMember;
            const callable = Callable.capture(lua, -1);
            members.append(allocator, .{ .name = try lua.toString(-2), .callable = callable }) catch |err| {
                callable.deinit();
                return err;
            };
            lua.pop(1);
        }
        return .{
            .callable = Callable.capture(lua, table),
            .members = try members.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: Resolved, allocator: Allocator) void {
        self.callable.deinit();
        for (self.members) |member_value| member_value.callable.deinit();
        allocator.free(self.members);
    }

    pub fn select(self: Resolved, index: i32, name: []const u8) ?usize {
        for (self.members, 0..) |member_value, member_index| {
            if (!std.mem.eql(u8, member_value.name, name)) continue;
            const lua = self.callable.state;
            const value = lua.absIndex(index);
            _ = lua.getIndexRaw(zlua.registry_index, self.callable.reference);
            _ = lua.pushString(name);
            _ = lua.getTableRaw(-2);
            const matches = lua.equalRaw(value, -1);
            lua.pop(2);
            return if (matches) member_index else null;
        }
        return null;
    }
};

pub fn pushModuleProxy(lua: *zlua.Lua, value: *const Resolved, config: *const []const u8) void {
    lua.createTable(0, @intCast(value.members.len));
    for (value.members) |*member_value| {
        _ = lua.pushString(member_value.name);
        pushNativeProxy(lua, &member_value.callable, config, true);
        lua.setTableRaw(-3);
    }
    lua.createTable(0, 2);
    pushProxy(lua, &value.callable, config, 2);
    lua.setField(-2, "__call");
    lua.pushBoolean(false);
    lua.setField(-2, "__metatable");
    lua.setMetatable(-2);
}

pub fn pushLoader(lua: *zlua.Lua, value: *const Resolved, config: *const []const u8) void {
    lua.pushLightUserdata(@ptrCast(value));
    lua.pushLightUserdata(@ptrCast(config));
    lua.pushClosure(zlua.wrap(loadProxy), 2);
}

pub fn pushProxy(lua: *zlua.Lua, value: *const Callable, config: *const []const u8, input: i32) void {
    lua.pushLightUserdata(@ptrCast(value));
    lua.pushLightUserdata(@ptrCast(config));
    lua.pushInteger(input);
    lua.pushClosure(zlua.wrap(callProxy), 3);
}

pub fn pushNativeProxy(lua: *zlua.Lua, value: *const Callable, config: *const []const u8, prepend_config: bool) void {
    lua.pushLightUserdata(@ptrCast(value));
    lua.pushLightUserdata(@ptrCast(config));
    lua.pushBoolean(prepend_config);
    lua.pushClosure(zlua.wrap(callNativeProxy), 3);
}

fn loadProxy(lua: *zlua.Lua) i32 {
    const value: *const Resolved = @ptrCast(@alignCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?));
    const config: *const []const u8 = @ptrCast(@alignCast(lua.toPointer(zlua.Lua.upvalueIndex(2)).?));
    pushModuleProxy(lua, value, config);
    return 1;
}

fn callProxy(lua: *zlua.Lua) !i32 {
    const value: *const Callable = @ptrCast(@alignCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?));
    const config: *const []const u8 = @ptrCast(@alignCast(lua.toPointer(zlua.Lua.upvalueIndex(2)).?));
    const input: i32 = @intCast(try lua.toInteger(zlua.Lua.upvalueIndex(3)));
    const output = value.call(lua.allocator(), try lua_state.bytes(lua, input), config.*) catch |err| {
        if (err == error.Canceled) lua_state.control(lua).cancellation.cancel();
        return err;
    };
    defer lua.allocator().free(output);
    _ = lua.pushString(output);
    return 1;
}

fn callNativeProxy(lua: *zlua.Lua) !i32 {
    const value: *const Callable = @ptrCast(@alignCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?));
    const config: *const []const u8 = @ptrCast(@alignCast(lua.toPointer(zlua.Lua.upvalueIndex(2)).?));
    const target = value.state;
    const arguments = lua.getTop();
    const top = target.getTop();
    defer target.setTop(top);
    target.pushFunction(zlua.wrap(lua_state.traceback));
    const message_handler = target.getTop();
    _ = target.getIndexRaw(zlua.registry_index, value.reference);
    const prepend_config = lua.toBoolean(zlua.Lua.upvalueIndex(3));
    if (prepend_config) _ = target.pushString(config.*);
    for (1..@as(usize, @intCast(arguments)) + 1) |index| try lua_state.transfer(lua, target, @intCast(index), 0);
    if (!prepend_config) _ = target.pushString(config.*);
    target.protectedCall(.{ .args = arguments + 1, .results = 1, .msg_handler = message_handler }) catch {
        if (lua_state.control(target).cancellation.canceled()) {
            lua_state.control(lua).cancellation.cancel();
            return error.Canceled;
        }
        _ = lua.pushString(target.toString(-1) catch "LuaFailure");
        lua.raiseError();
    };
    try lua_state.transfer(target, lua, -1, 0);
    return 1;
}

fn invoke(lua: *zlua.Lua) !i32 {
    const self: *const Callable = @ptrCast(@alignCast(lua.toPointer(1).?));
    const input: *const []const u8 = @ptrCast(@alignCast(lua.toPointer(2).?));
    const config: *const []const u8 = @ptrCast(@alignCast(lua.toPointer(3).?));
    _ = lua.getIndexRaw(zlua.registry_index, self.reference);
    _ = lua.pushString(input.*);
    _ = lua.pushString(config.*);
    lua.call(.{ .args = 2, .results = 1 });
    return 1;
}
