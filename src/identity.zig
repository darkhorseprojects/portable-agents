const std = @import("std");
const zlua = @import("zlua");

const Allocator = std.mem.Allocator;
const Ed25519 = std.crypto.sign.Ed25519;
pub const Identity = [32]u8;
pub const KeyPair = Ed25519.KeyPair;
pub const CallId = [32]u8;

pub const Router = struct {
    ptr: *anyopaque,
    call: *const fn (*anyopaque, []const u8, []const u8, Allocator, std.Io) anyerror![]u8,
};

pub const Caller = struct {
    allocator: Allocator,
    io: std.Io,
    key: *const KeyPair,
    router: ?Router,
    parent: ?CallId,
};

pub const Handle = struct {
    identity: Identity,
    grant_nonce: [32]u8,
    grant_signature: [64]u8,
    route: []const u8,

    pub fn call(self: Handle, caller: *const Caller, input: []const u8) ![]u8 {
        const router = caller.router orelse return error.NoRouter;
        const request = try makeCall(caller.allocator, caller.io, caller, self, input);
        defer caller.allocator.free(request);
        var id: CallId = undefined;
        std.crypto.hash.sha2.Sha256.hash(request[0 .. request.len - 64], &id, .{});
        const response = try router.call(router.ptr, self.route, request, caller.allocator, caller.io);
        defer caller.allocator.free(response);
        return verifyReturn(caller.allocator, id, self.identity, response);
    }
};

const Call = struct {
    from: Identity,
    to: Identity,
    parent: ?CallId,
    nonce: [32]u8,
    grant_nonce: [32]u8,
    grant_signature: [64]u8,
    input: []const u8,
    signature: [64]u8,
};

pub const Inbound = struct {
    arena: std.heap.ArenaAllocator,
    from: Identity,
    id: CallId,
    parent: ?CallId,
    input: []const u8,

    pub fn deinit(self: *Inbound, allocator: Allocator) void {
        _ = allocator;
        self.arena.deinit();
    }
};

const Return = struct {
    call: CallId,
    from: Identity,
    output: []const u8,
    signature: [64]u8,
};

pub fn issue(key: *const KeyPair, route: []const u8, io: std.Io) !Handle {
    const identity = key.public_key.toBytes();
    var nonce: [32]u8 = undefined;
    io.random(&nonce);
    var message: ["pa-grant-v1".len + 64]u8 = undefined;
    @memcpy(message[0.."pa-grant-v1".len], "pa-grant-v1");
    @memcpy(message["pa-grant-v1".len..][0..32], &identity);
    @memcpy(message["pa-grant-v1".len + 32 ..], &nonce);
    return .{
        .identity = identity,
        .grant_nonce = nonce,
        .grant_signature = (try key.sign(&message, null)).toBytes(),
        .route = route,
    };
}

pub fn encodeHandle(allocator: Allocator, handle: Handle) ![]u8 {
    if (handle.route.len > std.math.maxInt(u32)) return error.RouteTooLong;
    const bytes = try allocator.alloc(u8, 132 + handle.route.len);
    @memcpy(bytes[0..32], &handle.identity);
    @memcpy(bytes[32..64], &handle.grant_nonce);
    @memcpy(bytes[64..128], &handle.grant_signature);
    std.mem.writeInt(u32, bytes[128..132], @intCast(handle.route.len), .little);
    @memcpy(bytes[132..], handle.route);
    return bytes;
}

pub fn decodeHandle(allocator: Allocator, bytes: []const u8) !Handle {
    if (bytes.len < 132) return error.InvalidHandle;
    const route_len = std.mem.readInt(u32, bytes[128..132], .little);
    if (bytes.len != 132 + route_len) return error.InvalidHandle;
    return .{
        .identity = bytes[0..32].*,
        .grant_nonce = bytes[32..64].*,
        .grant_signature = bytes[64..128].*,
        .route = try allocator.dupe(u8, bytes[132..]),
    };
}

pub fn makeCall(allocator: Allocator, io: std.Io, caller: *const Caller, handle: Handle, input: []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, "pa-call-v1");
    try bytes.appendSlice(allocator, &caller.key.public_key.toBytes());
    try bytes.appendSlice(allocator, &handle.identity);
    try bytes.append(allocator, @intFromBool(caller.parent != null));
    try bytes.appendSlice(allocator, if (caller.parent) |*id| id else &([_]u8{0} ** 32));
    var nonce: [32]u8 = undefined;
    io.random(&nonce);
    try bytes.appendSlice(allocator, &nonce);
    try bytes.appendSlice(allocator, &handle.grant_nonce);
    try bytes.appendSlice(allocator, &handle.grant_signature);
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(input.len), .little);
    try bytes.appendSlice(allocator, &length);
    try bytes.appendSlice(allocator, input);
    const signature = try caller.key.sign(bytes.items, null);
    try bytes.appendSlice(allocator, &signature.toBytes());
    return bytes.toOwnedSlice(allocator);
}

pub fn verifyCall(allocator: Allocator, key: *const KeyPair, encoded: []const u8) !Inbound {
    const fixed = "pa-call-v1".len + 32 + 32 + 1 + 32 + 32 + 32 + 64 + 8 + 64;
    if (encoded.len < fixed or !std.mem.startsWith(u8, encoded, "pa-call-v1")) return error.InvalidCall;
    var at: usize = "pa-call-v1".len;
    const from: Identity = encoded[at..][0..32].*;
    at += 32;
    const to: Identity = encoded[at..][0..32].*;
    at += 32;
    if (!std.mem.eql(u8, &to, &key.public_key.toBytes())) return error.WrongTarget;
    const has_parent = encoded[at];
    at += 1;
    if (has_parent > 1) return error.InvalidCall;
    const parent_bytes: CallId = encoded[at..][0..32].*;
    at += 32;
    at += 32;
    const grant_nonce: [32]u8 = encoded[at..][0..32].*;
    at += 32;
    const grant_signature = Ed25519.Signature.fromBytes(encoded[at..][0..64].*);
    at += 64;
    const input_len = std.mem.readInt(u64, encoded[at..][0..8], .little);
    at += 8;
    if (input_len > std.math.maxInt(usize) or encoded.len != at + @as(usize, @intCast(input_len)) + 64) return error.InvalidCall;
    var grant: ["pa-grant-v1".len + 64]u8 = undefined;
    @memcpy(grant[0.."pa-grant-v1".len], "pa-grant-v1");
    @memcpy(grant["pa-grant-v1".len..][0..32], &to);
    @memcpy(grant["pa-grant-v1".len + 32 ..], &grant_nonce);
    try grant_signature.verify(&grant, try Ed25519.PublicKey.fromBytes(to));
    const signature = Ed25519.Signature.fromBytes(encoded[encoded.len - 64 ..][0..64].*);
    try signature.verify(encoded[0 .. encoded.len - 64], try Ed25519.PublicKey.fromBytes(from));
    var id: CallId = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded[0 .. encoded.len - 64], &id, .{});
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const input = try arena.allocator().dupe(u8, encoded[at .. encoded.len - 64]);
    return .{ .arena = arena, .from = from, .id = id, .parent = if (has_parent == 1) parent_bytes else null, .input = input };
}

pub fn makeReturn(allocator: Allocator, key: *const KeyPair, call: CallId, output: []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, "pa-return-v1");
    try bytes.appendSlice(allocator, &call);
    try bytes.appendSlice(allocator, &key.public_key.toBytes());
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(output.len), .little);
    try bytes.appendSlice(allocator, &length);
    try bytes.appendSlice(allocator, output);
    try bytes.appendSlice(allocator, &(try key.sign(bytes.items, null)).toBytes());
    return bytes.toOwnedSlice(allocator);
}

pub fn verifyReturn(allocator: Allocator, call: CallId, from: Identity, encoded: []const u8) ![]u8 {
    const prefix = "pa-return-v1".len;
    if (encoded.len < prefix + 32 + 32 + 8 + 64 or !std.mem.startsWith(u8, encoded, "pa-return-v1")) return error.InvalidReturn;
    if (!std.mem.eql(u8, encoded[prefix..][0..32], &call)) return error.WrongCall;
    if (!std.mem.eql(u8, encoded[prefix + 32 ..][0..32], &from)) return error.WrongTarget;
    const at = prefix + 64;
    const length = std.mem.readInt(u64, encoded[at..][0..8], .little);
    if (length > std.math.maxInt(usize) or encoded.len != at + 8 + @as(usize, @intCast(length)) + 64) return error.InvalidReturn;
    const signature = Ed25519.Signature.fromBytes(encoded[encoded.len - 64 ..][0..64].*);
    try signature.verify(encoded[0 .. encoded.len - 64], try Ed25519.PublicKey.fromBytes(from));
    return allocator.dupe(u8, encoded[at + 8 .. encoded.len - 64]);
}

pub fn pushHandle(lua: *zlua.Lua, handle: Handle, caller: *const Caller) !void {
    const encoded = try encodeHandle(caller.allocator, handle);
    defer caller.allocator.free(encoded);
    const Callbacks = struct {
        fn pair(state: *zlua.Lua) struct { []const u8, *const Caller } {
            const bytes = state.toString(zlua.Lua.upvalueIndex(1)) catch unreachable;
            const value: *const Caller = @ptrCast(@alignCast(state.toPointer(zlua.Lua.upvalueIndex(2)).?));
            return .{ bytes, value };
        }
        fn id(state: *zlua.Lua) i32 {
            const bytes = pair(state)[0];
            _ = state.pushString(bytes[0..32]);
            return 1;
        }
        fn exportValue(state: *zlua.Lua) i32 {
            _ = state.pushString(pair(state)[0]);
            return 1;
        }
        fn callValue(state: *zlua.Lua) !i32 {
            const values = pair(state);
            const imported = try decodeHandle(values[1].allocator, values[0]);
            defer values[1].allocator.free(imported.route);
            const output = try imported.call(values[1], state.checkString(1));
            defer values[1].allocator.free(output);
            _ = state.pushString(output);
            return 1;
        }
    };
    lua.createTable(0, 3);
    inline for (.{ .{ "id", Callbacks.id }, .{ "export", Callbacks.exportValue }, .{ "call", Callbacks.callValue } }) |field| {
        _ = lua.pushString(encoded);
        lua.pushLightUserdata(caller);
        lua.pushClosure(zlua.wrap(field[1]), 2);
        lua.setField(-2, field[0]);
    }
}
