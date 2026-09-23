const std = @import("std");
const zlua = @import("zlua");
const lua_state = @import("../lua.zig");

pub fn install(lua: *zlua.Lua, client: *std.http.Client) void {
    lua.pushLightUserdata(client);
    lua.pushClosure(zlua.wrap(httpRequest), 1);
    lua.setField(-2, "http");
}

fn httpRequest(lua: *zlua.Lua) !i32 {
    errdefer lua_state.control(lua).io.checkCancel() catch lua_state.control(lua).cancellation.cancel();
    if (lua.typeOf(1) != .string or lua.typeOf(2) != .string or lua.typeOf(3) != .string or
        (!lua.isNoneOrNil(4) and lua.typeOf(4) != .string) or
        (!lua.isNoneOrNil(5) and lua.typeOf(5) != .table) or
        (!lua.isNoneOrNil(7) and !lua.isFunction(7))) return error.InvalidRequest;
    const maximum: ?usize = if (lua.isNoneOrNil(6)) null else std.math.cast(usize, try lua.toInteger(6)) orelse return error.InvalidResponseLimit;
    if (maximum == 0 or !lua.isNoneOrNil(7) and maximum == null) return error.InvalidResponseLimit;
    const origin = try lua.toString(1);
    try validateRequestBytes(origin);
    var uri = try std.Uri.parse(origin);
    if ((!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) or
        uri.host == null or uri.user != null or uri.password != null or !uri.path.isEmpty() or
        uri.query != null or uri.fragment != null) return error.InvalidOrigin;
    const method = std.meta.stringToEnum(std.http.Method, try lua.toString(2)) orelse return error.InvalidMethod;
    const path = try lua.toString(3);
    validateRequestBytes(path) catch return error.InvalidPath;
    if (path.len == 0 or path[0] != '/' or
        (path.len > 1 and path[1] == '/') or
        std.mem.indexOfScalar(u8, path, '\\') != null)
    {
        return error.InvalidPath;
    }
    const relative = std.Uri.parseAfterScheme("", path) catch return error.InvalidPath;
    if (relative.host != null or relative.fragment != null) return error.InvalidPath;
    uri.path = relative.path;
    uri.query = relative.query;
    const headers = try requestHeaders(lua, 5);
    defer if (headers) |extra| lua.allocator().free(extra);
    const client: *std.http.Client = @ptrCast(@alignCast(@constCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?)));
    var request = try client.request(method, uri, .{
        .redirect_behavior = .unhandled,
        .extra_headers = headers orelse &.{},
        .keep_alive = false,
    });
    defer request.deinit();
    const body = if (lua.isNoneOrNil(4)) null else try lua.toString(4);
    if (method.requestHasBody()) {
        try request.sendBodyComplete(@constCast(body orelse ""));
    } else {
        if (body) |bytes| if (bytes.len != 0) return error.UnexpectedBody;
        try request.sendBodiless();
    }
    var response = try request.receiveHead(&.{});
    const status: i64 = @intCast(@intFromEnum(response.head.status));
    if (maximum) |limit| if (response.head.content_length) |length| {
        if (length > limit) return error.ResponseTooLarge;
    };
    var body_buffer: [8192]u8 = undefined;
    const reader = response.reader(&body_buffer);
    if (!lua.isNoneOrNil(7)) {
        var chunk: [8192]u8 = undefined;
        var received: usize = 0;
        while (true) {
            try lua_state.control(lua).io.checkCancel();
            var buffers: [1][]u8 = .{&chunk};
            const size = reader.readVec(&buffers) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (size > maximum.? -| received) return error.ResponseTooLarge;
            received += size;
            if (size == 0) continue;
            lua.pushValue(7);
            lua.pushInteger(status);
            _ = lua.pushString(chunk[0..size]);
            try lua_state.protect(lua, .{ .args = 2 });
        }
        lua.pushInteger(status);
        return 1;
    }
    const response_body = try reader.allocRemaining(lua.allocator(), if (maximum) |limit| .limited(limit) else .unlimited);
    defer lua.allocator().free(response_body);
    lua.pushInteger(status);
    _ = lua.pushString(response_body);
    return 2;
}

fn requestHeaders(lua: *zlua.Lua, index: i32) !?[]std.http.Header {
    if (lua.isNoneOrNil(index)) return null;
    var headers: std.ArrayList(std.http.Header) = .empty;
    errdefer headers.deinit(lua.allocator());
    lua.pushNil();
    while (lua.next(lua.absIndex(index))) {
        if (lua.typeOf(-2) != .string or lua.typeOf(-1) != .string) return error.InvalidHeader;
        const header: std.http.Header = .{ .name = try lua.toString(-2), .value = try lua.toString(-1) };
        try validateHeader(header.name, header.value);
        try headers.append(lua.allocator(), header);
        lua.pop(1);
    }
    return if (headers.items.len == 0) null else try headers.toOwnedSlice(lua.allocator());
}

fn validateRequestBytes(value: []const u8) !void {
    for (value) |byte| if (byte <= ' ' or byte == 0x7f) return error.InvalidRequestBytes;
}

fn validateHeader(name: []const u8, value: []const u8) !void {
    if (name.len == 0) return error.InvalidHeader;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null) return error.InvalidHeader;
    }
    for (value) |byte| if (byte < ' ' and byte != '\t' or byte == 127) return error.InvalidHeader;
    inline for (.{ "host", "content-length", "transfer-encoding", "connection", "proxy-connection", "proxy-authorization", "trailer", "upgrade" }) |blocked| {
        if (std.ascii.eqlIgnoreCase(name, blocked)) return error.ForbiddenHeader;
    }
}
