const std = @import("std");
const zlua = @import("zlua");
const lua = @import("lua.zig");
const fs = @import("host/fs.zig");
const http = @import("host/http.zig");
const process = @import("host/process.zig");

pub fn install(state: *zlua.Lua, io: *const std.Io, client: *std.http.Client, cancellation: *lua.Cancellation) !void {
    try fs.install(state, io, cancellation);
    http.install(state, client, cancellation);
    process.install(state, io, cancellation);
}
