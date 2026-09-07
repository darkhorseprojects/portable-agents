const std = @import("std");
const zlua = @import("zlua");

const Allocator = std.mem.Allocator;
const Ed25519 = std.crypto.sign.Ed25519;
const grant_domain = "pa-grant-v1";
const call_domain = "pa-call-v1";
const return_domain = "pa-return-v1";
const zero_id = [_]u8{0} ** 32;

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
    canceled: *std.atomic.Value(bool),

    pub fn observe(self: *Caller, err: anyerror) void {
        if (err == error.Canceled) self.canceled.store(true, .release);
    }
};

pub const Handle = struct {
    identity: Identity,
    grant_nonce: [32]u8,
    grant_signature: [64]u8,
    route: []const u8,

    pub fn call(self: Handle, caller: *Caller, input: []const u8) ![]u8 {
        const router = caller.router orelse return error.NoRouter;
        var id: CallId = undefined;
        const request = try makeCall(caller.allocator, caller, self, input, &id);
        defer caller.allocator.free(request);
        const response = router.call(router.ptr, self.route, request, caller.allocator, caller.io) catch |err| {
            caller.observe(err);
            return err;
        };
        defer caller.allocator.free(response);
        return verifyReturn(caller.allocator, id, self.identity, response);
    }
};

pub const Inbound = struct {
    from: Identity,
    id: CallId,
    parent: ?CallId,
    input: []u8,

    pub fn deinit(self: *Inbound, allocator: Allocator) void {
        allocator.free(self.input);
    }
};

pub fn issue(key: *const KeyPair, route: []const u8, io: std.Io) !Handle {
    const target = key.public_key.toBytes();
    var nonce: [32]u8 = undefined;
    io.random(&nonce);
    return .{
        .identity = target,
        .grant_nonce = nonce,
        .grant_signature = (try key.sign(&grantMessage(target, nonce), null)).toBytes(),
        .route = route,
    };
}

pub fn encodeHandle(allocator: Allocator, handle: Handle) ![]u8 {
    const size = try std.math.add(usize, 132, handle.route.len);
    if (handle.route.len > std.math.maxInt(u32)) return error.RouteTooLong;
    const encoded = try allocator.alloc(u8, size);
    var writer = std.Io.Writer.fixed(encoded);
    try writer.writeAll(&handle.identity);
    try writer.writeAll(&handle.grant_nonce);
    try writer.writeAll(&handle.grant_signature);
    try writer.writeInt(u32, @intCast(handle.route.len), .little);
    try writer.writeAll(handle.route);
    return encoded;
}

pub fn decodeHandle(encoded: []const u8) !Handle {
    if (encoded.len < 132) return error.InvalidHandle;
    var reader = std.Io.Reader.fixed(encoded);
    const target = (try reader.takeArray(32)).*;
    const nonce = (try reader.takeArray(32)).*;
    const signature = (try reader.takeArray(64)).*;
    const route_len: usize = try reader.takeInt(u32, .little);
    if (reader.bufferedLen() != route_len) return error.InvalidHandle;
    return .{
        .identity = target,
        .grant_nonce = nonce,
        .grant_signature = signature,
        .route = try reader.take(route_len),
    };
}

pub fn makeCall(allocator: Allocator, caller: *const Caller, handle: Handle, input: []const u8, id: *CallId) ![]u8 {
    if (input.len > std.math.maxInt(u64)) return error.InputTooLong;
    const unsigned_len = try std.math.add(usize, call_domain.len + 233, input.len);
    const encoded = try allocator.alloc(u8, try std.math.add(usize, unsigned_len, 64));
    errdefer allocator.free(encoded);
    var writer = std.Io.Writer.fixed(encoded);
    try writer.writeAll(call_domain);
    try writer.writeAll(&caller.key.public_key.toBytes());
    try writer.writeAll(&handle.identity);
    try writer.writeByte(@intFromBool(caller.parent != null));
    try writer.writeAll(if (caller.parent) |*parent| parent else &zero_id);
    var nonce: [32]u8 = undefined;
    caller.io.random(&nonce);
    try writer.writeAll(&nonce);
    try writer.writeAll(&handle.grant_nonce);
    try writer.writeAll(&handle.grant_signature);
    try writer.writeInt(u64, @intCast(input.len), .little);
    try writer.writeAll(input);
    std.crypto.hash.sha2.Sha256.hash(encoded[0..unsigned_len], id, .{});
    try writer.writeAll(&(try caller.key.sign(encoded[0..unsigned_len], null)).toBytes());
    return encoded;
}

pub fn verifyCall(allocator: Allocator, key: *const KeyPair, encoded: []const u8) !Inbound {
    const unsigned_fixed = call_domain.len + 233;
    if (encoded.len < unsigned_fixed + 64) return error.InvalidCall;
    var reader = std.Io.Reader.fixed(encoded);
    if (!std.mem.eql(u8, try reader.take(call_domain.len), call_domain)) return error.InvalidCall;
    const from = (try reader.takeArray(32)).*;
    const to = (try reader.takeArray(32)).*;
    if (!std.mem.eql(u8, &to, &key.public_key.toBytes())) return error.WrongTarget;
    const has_parent = try reader.takeByte();
    if (has_parent > 1) return error.InvalidCall;
    const parent = (try reader.takeArray(32)).*;
    try reader.discardAll(32);
    const grant_nonce = (try reader.takeArray(32)).*;
    const grant_signature = Ed25519.Signature.fromBytes((try reader.takeArray(64)).*);
    const input_len = std.math.cast(usize, try reader.takeInt(u64, .little)) orelse return error.InvalidCall;
    if (input_len > reader.bufferedLen() or reader.bufferedLen() - input_len != 64) return error.InvalidCall;
    const input = try reader.take(input_len);
    const signature = Ed25519.Signature.fromBytes((try reader.takeArray(64)).*);
    try grant_signature.verify(&grantMessage(to, grant_nonce), try Ed25519.PublicKey.fromBytes(to));
    try signature.verify(encoded[0 .. encoded.len - 64], try Ed25519.PublicKey.fromBytes(from));
    var id: CallId = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded[0 .. encoded.len - 64], &id, .{});
    return .{
        .from = from,
        .id = id,
        .parent = if (has_parent == 1) parent else null,
        .input = try allocator.dupe(u8, input),
    };
}

pub fn makeReturn(allocator: Allocator, key: *const KeyPair, call: CallId, output: []const u8) ![]u8 {
    if (output.len > std.math.maxInt(u64)) return error.OutputTooLong;
    const unsigned_len = try std.math.add(usize, return_domain.len + 72, output.len);
    const encoded = try allocator.alloc(u8, try std.math.add(usize, unsigned_len, 64));
    errdefer allocator.free(encoded);
    var writer = std.Io.Writer.fixed(encoded);
    try writer.writeAll(return_domain);
    try writer.writeAll(&call);
    try writer.writeAll(&key.public_key.toBytes());
    try writer.writeInt(u64, @intCast(output.len), .little);
    try writer.writeAll(output);
    try writer.writeAll(&(try key.sign(encoded[0..unsigned_len], null)).toBytes());
    return encoded;
}

pub fn verifyReturn(allocator: Allocator, call: CallId, from: Identity, encoded: []const u8) ![]u8 {
    if (encoded.len < return_domain.len + 136) return error.InvalidReturn;
    var reader = std.Io.Reader.fixed(encoded);
    if (!std.mem.eql(u8, try reader.take(return_domain.len), return_domain)) return error.InvalidReturn;
    if (!std.mem.eql(u8, try reader.take(32), &call)) return error.WrongCall;
    if (!std.mem.eql(u8, try reader.take(32), &from)) return error.WrongTarget;
    const output_len = std.math.cast(usize, try reader.takeInt(u64, .little)) orelse return error.InvalidReturn;
    if (output_len > reader.bufferedLen() or reader.bufferedLen() - output_len != 64) return error.InvalidReturn;
    const output = try reader.take(output_len);
    const signature = Ed25519.Signature.fromBytes((try reader.takeArray(64)).*);
    try signature.verify(encoded[0 .. encoded.len - 64], try Ed25519.PublicKey.fromBytes(from));
    return allocator.dupe(u8, output);
}

pub fn pushHandle(lua: *zlua.Lua, allocator: Allocator, handle: Handle) !void {
    const encoded = try encodeHandle(allocator, handle);
    defer allocator.free(encoded);
    _ = lua.getGlobal("pa");
    _ = lua.getField(-1, "_handle");
    lua.remove(-2);
    _ = lua.pushString(encoded);
    try lua.protectedCall(.{ .args = 1, .results = 1 });
}

fn grantMessage(target: Identity, nonce: [32]u8) [grant_domain.len + 64]u8 {
    var message: [grant_domain.len + 64]u8 = undefined;
    @memcpy(message[0..grant_domain.len], grant_domain);
    @memcpy(message[grant_domain.len..][0..32], &target);
    @memcpy(message[grant_domain.len + 32 ..], &nonce);
    return message;
}
