const std = @import("std");
const zlua = @import("zlua");

const Allocator = std.mem.Allocator;
pub const Header = std.http.Header;

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
    headers: []const Header,
    eval: bool,
    max_bytes: usize,

    pub fn init(allocator: Allocator, config: Config) !Grant {
        const origin = try allocator.dupe(u8, config.origin);
        const uri = try std.Uri.parse(origin);
        if ((!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) or uri.host == null or !uri.path.isEmpty() or uri.query != null or uri.fragment != null) return error.InvalidOrigin;
        const headers = try allocator.alloc(Header, config.headers.len);
        for (config.headers, headers) |source, *target| {
            if (source.name.len == 0 or std.mem.indexOfAny(u8, source.name, ":\r\n") != null or std.mem.indexOfAny(u8, source.value, "\r\n") != null) return error.InvalidHeader;
            target.* = .{
                .name = try allocator.dupe(u8, source.name),
                .value = try allocator.dupe(u8, source.value),
            };
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
        lua.createTable(0, 1);
        lua.pushLightUserdata(self);
        lua.pushLightUserdata(client);
        lua.pushClosure(zlua.wrap(request), 2);
        lua.setField(-2, "request");
    }

    fn request(lua: *zlua.Lua) !i32 {
        const self: *const Grant = @ptrCast(@alignCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?));
        const client: *std.http.Client = @ptrCast(@alignCast(@constCast(lua.toPointer(zlua.Lua.upvalueIndex(2)).?)));
        if (lua.typeOf(1) != .string or lua.typeOf(2) != .string or (lua.getTop() >= 3 and lua.typeOf(3) != .string)) return error.ExpectedBytes;
        const method = std.meta.stringToEnum(std.http.Method, try lua.toString(1)) orelse return error.InvalidMethod;
        const path = try lua.toString(2);
        const body = if (lua.getTop() >= 3) try lua.toString(3) else null;
        if (path.len == 0 or path[0] != '/' or (path.len > 1 and path[1] == '/') or std.mem.indexOfAny(u8, path, "\\\r\n") != null) return error.InvalidPath;
        if (body) |bytes| if (bytes.len > self.max_bytes) return error.BodyTooLarge;
        const url = try std.mem.concat(lua.allocator(), u8, &.{ self.origin, path });
        defer lua.allocator().free(url);
        var value = try client.request(method, try std.Uri.parse(url), .{
            .redirect_behavior = .unhandled,
            .extra_headers = self.headers,
        });
        defer value.deinit();
        if (body) |bytes| try value.sendBodyComplete(@constCast(bytes)) else try value.sendBodiless();
        var redirect_buffer: [4096]u8 = undefined;
        var response = try value.receiveHead(&redirect_buffer);
        var transfer_buffer: [8192]u8 = undefined;
        const data = try response.reader(&transfer_buffer).allocRemaining(lua.allocator(), .limited(self.max_bytes));
        defer lua.allocator().free(data);
        lua.pushInteger(@intCast(@intFromEnum(response.head.status)));
        _ = lua.pushString(data);
        return 2;
    }
};
