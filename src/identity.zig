const std = @import("std");
const zlua = @import("zlua");

pub const Identity = [32]u8;

var marker: u8 = 0;

pub fn generate(io: std.Io) Identity {
    var value: Identity = undefined;
    io.random(&value);
    return value;
}

pub fn mark(lua: *zlua.Lua, metatable: i32, value: Identity) void {
    const table = lua.absIndex(metatable);
    _ = lua.pushString(&value);
    lua.setPtrRaw(table, &marker);
}

pub fn read(lua: *zlua.Lua, index: i32) !Identity {
    lua.getMetatable(index) catch return error.ExpectedInterface;
    defer lua.pop(1);
    if (lua.getPtrRaw(-1, &marker) != .string) {
        lua.pop(1);
        return error.ExpectedInterface;
    }
    defer lua.pop(1);
    const bytes = try lua.toString(-1);
    if (bytes.len != @sizeOf(Identity)) return error.ExpectedInterface;
    return bytes[0..@sizeOf(Identity)].*;
}
