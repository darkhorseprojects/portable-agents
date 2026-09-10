const std = @import("std");
const zlua = @import("zlua");

pub fn install(lua: *zlua.Lua, client: *std.http.Client, canceled: *std.atomic.Value(bool)) void {
    lua.pushLightUserdata(client);
    lua.pushLightUserdata(canceled);
    lua.pushClosure(zlua.wrap(create), 2);
    lua.setField(-2, "http");
}

fn create(lua: *zlua.Lua) !i32 {
    if (lua.typeOf(1) != .string) return error.ExpectedOrigin;
    const origin = try lua.toString(1);
    try validateRequestBytes(origin);
    const uri = try std.Uri.parse(origin);
    if ((!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) or
        uri.host == null or uri.user != null or uri.password != null or !uri.path.isEmpty() or
        uri.query != null or uri.fragment != null)
    {
        return error.InvalidOrigin;
    }
    lua.createTable(0, 1);
    lua.pushValue(1);
    lua.pushValue(zlua.Lua.upvalueIndex(1));
    lua.pushValue(zlua.Lua.upvalueIndex(2));
    lua.pushClosure(zlua.wrap(request), 3);
    lua.setField(-2, "request");
    return 1;
}

fn request(lua: *zlua.Lua) !i32 {
    const canceled: *std.atomic.Value(bool) = @ptrCast(@alignCast(@constCast(lua.toPointer(zlua.Lua.upvalueIndex(3)).?)));
    return requestValue(lua) catch |err| {
        if (err == error.Canceled) canceled.store(true, .release);
        return err;
    };
}

fn requestValue(lua: *zlua.Lua) !i32 {
    if (lua.typeOf(1) != .string or lua.typeOf(2) != .string or
        (lua.getTop() >= 3 and !lua.isNil(3) and lua.typeOf(3) != .string) or
        (lua.getTop() >= 4 and !lua.isNil(4) and lua.typeOf(4) != .table))
    {
        return error.InvalidRequest;
    }
    const method = std.meta.stringToEnum(std.http.Method, try lua.toString(1)) orelse return error.InvalidMethod;
    const path = try lua.toString(2);
    validateRequestBytes(path) catch return error.InvalidPath;
    if (path.len == 0 or path[0] != '/' or (path.len > 1 and path[1] == '/') or std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidPath;
    var uri = try std.Uri.parse(try lua.toString(zlua.Lua.upvalueIndex(1)));
    const relative = try std.Uri.parse(path);
    if (relative.host != null or relative.fragment != null) return error.InvalidPath;
    uri.path = relative.path;
    uri.query = relative.query;
    const extra = try requestHeaders(lua, 4);
    defer if (extra) |headers| lua.allocator().free(headers);
    const client: *std.http.Client = @ptrCast(@alignCast(@constCast(lua.toPointer(zlua.Lua.upvalueIndex(2)).?)));
    var value = try client.request(method, uri, .{
        .redirect_behavior = .unhandled,
        .extra_headers = extra orelse &.{},
    });
    defer value.deinit();
    const body = if (lua.getTop() >= 3 and !lua.isNil(3)) try lua.toString(3) else null;
    if (method.requestHasBody()) {
        try value.sendBodyComplete(@constCast(body orelse ""));
    } else {
        if (body) |bytes| if (bytes.len != 0) return error.UnexpectedBody;
        try value.sendBodiless();
    }
    var head_buffer: [4096]u8 = undefined;
    var response = try value.receiveHead(&head_buffer);
    var body_buffer: [8192]u8 = undefined;
    const data = try response.reader(&body_buffer).allocRemaining(lua.allocator(), .unlimited);
    defer lua.allocator().free(data);
    lua.pushInteger(@intCast(@intFromEnum(response.head.status)));
    _ = lua.pushString(data);
    return 2;
}

fn requestHeaders(lua: *zlua.Lua, index: i32) !?[]std.http.Header {
    if (lua.getTop() < index or lua.isNil(index)) return null;
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
