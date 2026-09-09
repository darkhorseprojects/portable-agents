const std = @import("std");
const zlua = @import("zlua");
const fs = @import("host/fs.zig");
const http = @import("host/http.zig");
const process = @import("host/process.zig");

pub fn install(lua: *zlua.Lua, io: *const std.Io, client: *std.http.Client, canceled: *std.atomic.Value(bool)) !void {
    try fs.install(lua, io, canceled);
    http.install(lua, client, canceled);
    process.install(lua, io, canceled);
}
