const std = @import("std");
const zlua = @import("zlua");
const fs = @import("host/fs.zig");
const http = @import("host/http.zig");
const process = @import("host/process.zig");

pub fn install(state: *zlua.Lua, client: *std.http.Client) !void {
    try fs.install(state);
    http.install(state, client);
    process.install(state);
}
