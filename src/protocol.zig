const std = @import("std");
const pa = @import("pa");

const Allocator = std.mem.Allocator;

const WireLimits = struct {
    bytes: ?usize = null,
    steps: ?[]const u8 = null,
};

const WireAgent = struct {
    source: []const u8,
    agentId: []const u8,
    limits: WireLimits = .{},
};

const WireImport = struct {
    name: []const u8,
    agent: usize,
    entry: []const u8,
};

const Request = struct {
    version: u8,
    agents: []const WireAgent,
    imports: []const WireImport = &.{},
    entry: []const u8,
    input: []const u8,
};

const OwnedAgent = struct {
    image: pa.Image,
    agent: pa.Agent,

    fn init(self: *OwnedAgent, allocator: Allocator, io: std.Io, wire: WireAgent) !void {
        self.image = try pa.Image.init(allocator, io, wire.source);
        errdefer self.image.deinit();
        self.agent = pa.Agent.init(allocator, io, .{ .agent_id = try decodeAgentId(wire.agentId), .limits = try decodeLimits(wire.limits) });
    }

    fn deinit(self: *OwnedAgent) void {
        self.agent.deinit();
        self.image.deinit();
    }
};

pub fn call(allocator: Allocator, io: std.Io, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    const output = run(allocator, io, reader) catch |err| {
        try write(writer, .{ .result = .{ .@"error" = @errorName(err) } });
        return;
    };
    defer allocator.free(output);
    const encoded = try encodeBase64(allocator, output);
    defer allocator.free(encoded);
    try write(writer, .{ .result = .{ .output = encoded } });
}

fn run(allocator: Allocator, io: std.Io, reader: *std.Io.Reader) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const bytes = try reader.allocRemaining(scratch, .unlimited);
    if (bytes.len == 0) return error.MissingRequest;
    const request = try std.json.parseFromSliceLeaky(Request, scratch, bytes, .{});
    if (request.version != 3 or request.agents.len == 0) return error.InvalidProtocol;
    const owned = try scratch.alloc(OwnedAgent, request.agents.len);
    var initialized: usize = 0;
    defer while (initialized > 0) {
        initialized -= 1;
        owned[initialized].deinit();
    };
    for (owned, request.agents) |*item, wire| {
        try item.init(allocator, io, wire);
        initialized += 1;
    }
    const imports = try scratch.alloc(pa.Import, request.imports.len);
    for (imports, request.imports) |*value, wire| {
        if (wire.agent >= owned.len) return error.InvalidProtocol;
        const agent = &owned[wire.agent];
        value.* = .{ .name = wire.name, .agent = &agent.agent, .image = &agent.image, .entry = wire.entry };
    }
    const root = &owned[0];
    return root.agent.call(allocator, &root.image, request.entry, try decodeBase64(scratch, request.input), imports);
}

fn decodeLimits(wire: WireLimits) !pa.Limits {
    var limits: pa.Limits = .{};
    if (wire.bytes) |bytes| limits.bytes = bytes;
    if (wire.steps) |steps| limits.steps = try std.fmt.parseInt(u64, steps, 10);
    return limits;
}

fn encodeBase64(allocator: Allocator, bytes: []const u8) ![]const u8 {
    const output = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    return std.base64.standard.Encoder.encode(output, bytes);
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
