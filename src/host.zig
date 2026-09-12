const std = @import("std");
const zlua = @import("zlua");
const runtime = @import("runtime.zig");
const fs = @import("host/fs.zig");
const http = @import("host/http.zig");
const process = @import("host/process.zig");

pub fn install(lua: *zlua.Lua, io: *const std.Io, client: *std.http.Client, cancellation: *runtime.Cancellation) !void {
    try fs.install(lua, io, cancellation);
    http.install(lua, client, cancellation);
    process.install(lua, io, cancellation);
}
