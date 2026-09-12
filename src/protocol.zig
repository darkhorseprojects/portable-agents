const std = @import("std");
const pa = @import("pa");

const Allocator = std.mem.Allocator;

const WireImport = struct {
    name: []const u8,
    source: []const u8,
    agentId: []const u8,
    luaBytes: usize,
    luaSteps: []const u8,
    entry: []const u8,
};

const Request = struct {
    version: u8,
    agentId: []const u8,
    luaBytes: usize,
    luaSteps: []const u8,
    imports: []const WireImport = &.{},
    entry: []const u8,
    input: []const u8,
};

const OwnedImport = struct {
    image: pa.Image,
    agent: pa.Agent,

    fn init(self: *OwnedImport, allocator: Allocator, io: std.Io, wire: WireImport) !void {
        self.image = try pa.Image.init(allocator, io, wire.source);
        errdefer self.image.deinit();
        self.agent = pa.Agent.init(allocator, io, .{ .agent_id = try decodeAgentId(wire.agentId), .limits = try decodeLimits(wire.luaBytes, wire.luaSteps) });
    }

    fn deinit(self: *OwnedImport) void {
        self.agent.deinit();
        self.image.deinit();
    }
};

pub fn call(allocator: Allocator, io: std.Io, source: []const u8, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    const output = run(allocator, io, source, reader) catch |err| {
        try write(writer, .{ .result = .{ .@"error" = @errorName(err) } });
        return;
    };
    defer allocator.free(output);
    const encoded = try encodeBase64(allocator, output);
    defer allocator.free(encoded);
    try write(writer, .{ .result = .{ .output = encoded } });
}

fn run(allocator: Allocator, io: std.Io, source: []const u8, reader: *std.Io.Reader) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const bytes = try reader.allocRemaining(scratch, .unlimited);
    if (bytes.len == 0) return error.MissingRequest;
    const request = try std.json.parseFromSliceLeaky(Request, scratch, bytes, .{});
    if (request.version != 2) return error.InvalidProtocol;
    const owned = try scratch.alloc(OwnedImport, request.imports.len);
    var initialized: usize = 0;
    defer while (initialized > 0) {
        initialized -= 1;
        owned[initialized].deinit();
    };
    for (owned, request.imports) |*item, wire| {
        try item.init(allocator, io, wire);
        initialized += 1;
    }
    const imports = try scratch.alloc(pa.Import, owned.len);
    for (imports, owned, request.imports) |*value, *item, wire| value.* = .{ .name = wire.name, .agent = &item.agent, .image = &item.image, .entry = wire.entry };
    var image = try pa.Image.init(allocator, io, source);
    defer image.deinit();
    var agent = pa.Agent.init(allocator, io, .{ .agent_id = try decodeAgentId(request.agentId), .limits = try decodeLimits(request.luaBytes, request.luaSteps) });
    defer agent.deinit();
    return agent.call(allocator, &image, request.entry, try decodeBase64(scratch, request.input), imports);
}

fn decodeLimits(bytes: usize, steps: []const u8) !pa.Limits {
    return .{ .bytes = bytes, .steps = try std.fmt.parseInt(u64, steps, 10) };
}

fn encodeBase64(allocator: Allocator, bytes: []const u8) ![]u8 {
    const output = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    return @constCast(std.base64.standard.Encoder.encode(output, bytes));
}

fn decodeAgentId(encoded: []const u8) !pa.AgentId {
    var value: pa.AgentId = undefined;
    if (try std.base64.standard.Decoder.calcSizeForSlice(encoded) != value.len) return error.InvalidAgentId;
    try std.base64.standard.Decoder.decode(&value, encoded);
    return value;
}

fn decodeBase64(allocator: Allocator, encoded: []const u8) ![]u8 {
    const output = try allocator.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
    errdefer allocator.free(output);
    try std.base64.standard.Decoder.decode(output, encoded);
    return output;
}

fn write(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, writer);
    try writer.flush();
}
