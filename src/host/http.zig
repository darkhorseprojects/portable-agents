const std = @import("std");
const zlua = @import("zlua");

const Allocator = std.mem.Allocator;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Config = struct {
    name: []const u8,
    origin: []const u8,
    headers: []const Header = &.{},
    eval: bool = false,
    max_bytes: usize = 8 * 1024 * 1024,
};

pub const Grant = struct {
    name: []const u8,
    origin: []const u8,
    headers: []const std.http.Header,
    eval: bool,
    max_bytes: usize,

    pub fn init(allocator: Allocator, config: Config) !Grant {
        const origin = try allocator.dupe(u8, config.origin);
        const uri = try std.Uri.parse(origin);
        if ((!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) or uri.host == null or !uri.path.isEmpty() or uri.query != null or uri.fragment != null) return error.InvalidOrigin;
        const headers = try allocator.alloc(std.http.Header, config.headers.len);
        for (config.headers, headers) |source, *target| {
            if (source.name.len == 0 or std.mem.indexOfAny(u8, source.name, ":\r\n") != null or std.mem.indexOfAny(u8, source.value, "\r\n") != null) return error.InvalidHeader;
            target.* = .{ .name = try allocator.dupe(u8, source.name), .value = try allocator.dupe(u8, source.value) };
        }
        return .{
            .name = try allocator.dupe(u8, config.name),
            .origin = origin,
            .headers = headers,
            .eval = config.eval,
            .max_bytes = config.max_bytes,
        };
    }

    pub fn push(self: *const Grant, lua: *zlua.Lua, client: *std.http.Client) void {
        const Callback = struct {
            fn requestValue(state: *zlua.Lua) !i32 {
                const grant: *const Grant = @ptrCast(@alignCast(state.toPointer(zlua.Lua.upvalueIndex(1)).?));
                const http_client: *std.http.Client = @ptrCast(@alignCast(@constCast(state.toPointer(zlua.Lua.upvalueIndex(2)).?)));
                const body = if (state.getTop() >= 3) state.checkString(3) else null;
                const result = try grant.request(http_client, state.allocator(), state.checkString(1), state.checkString(2), body);
                defer state.allocator().free(result.body);
                state.pushInteger(@intCast(result.status));
                _ = state.pushString(result.body);
                return 2;
            }
        };
        lua.createTable(0, 1);
        lua.pushLightUserdata(self);
        lua.pushLightUserdata(client);
        lua.pushClosure(zlua.wrap(Callback.requestValue), 2);
        lua.setField(-2, "request");
    }

    fn request(self: *const Grant, client: *std.http.Client, allocator: Allocator, method_name: []const u8, path: []const u8, body: ?[]const u8) !struct { status: u16, body: []u8 } {
        const method = std.meta.stringToEnum(std.http.Method, method_name) orelse return error.InvalidMethod;
        if (path.len == 0 or path[0] != '/' or (path.len > 1 and path[1] == '/') or std.mem.indexOfAny(u8, path, "\\\r\n") != null) return error.InvalidPath;
        const url = try std.mem.concat(allocator, u8, &.{ self.origin, path });
        defer allocator.free(url);
        const uri = try std.Uri.parse(url);
        var request_value = try client.request(method, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = self.headers,
        });
        defer request_value.deinit();
        if (body) |bytes| try request_value.sendBodyComplete(@constCast(bytes)) else try request_value.sendBodiless();
        var redirect_buffer: [4096]u8 = undefined;
        var response = try request_value.receiveHead(&redirect_buffer);
        var transfer_buffer: [8192]u8 = undefined;
        const data = try response.reader(&transfer_buffer).allocRemaining(allocator, .limited(self.max_bytes));
        return .{ .status = @intFromEnum(response.head.status), .body = data };
    }
};
