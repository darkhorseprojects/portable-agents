const std = @import("std");
const pa = @import("pa");

const Allocator = std.mem.Allocator;

const WireAgent = struct {
    sourceDir: []const u8,
    entryModule: []const u8,
    limits: struct {
        memoryBytes: ?usize = null,
        instructions: ?[]const u8 = null,
    } = .{},
};

const WireImport = struct {
    name: []const u8,
    agent: usize,
    config: []const u8,
};

const Request = struct {
    version: u8,
    emits: bool,
    agents: []const WireAgent,
    imports: []const WireImport = &.{},
    input: []const u8,
    config: []const u8,
};

const Output = struct {
    allocator: Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    mutex: std.Io.Mutex = .init,

    fn emit(context: *anyopaque, bytes: []const u8) !void {
        const self: *Output = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const encoded = try self.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
        defer self.allocator.free(encoded);
        try write(self.writer, .{ .emit = std.base64.standard.Encoder.encode(encoded, bytes) });
    }

    fn result(self: *Output, bytes: []const u8) !void {
        const encoded = try self.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
        defer self.allocator.free(encoded);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try write(self.writer, .{ .result = .{ .output = std.base64.standard.Encoder.encode(encoded, bytes) } });
    }

    fn failure(self: *Output, err: anyerror) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try write(self.writer, .{ .result = .{ .@"error" = @errorName(err) } });
    }
};

pub fn call(allocator: Allocator, io: std.Io, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    var output: Output = .{ .allocator = allocator, .io = io, .writer = writer };
    const bytes = run(allocator, io, reader, &output) catch |err| {
        try output.failure(err);
        return;
    };
    defer allocator.free(bytes);
    try output.result(bytes);
}

fn run(allocator: Allocator, io: std.Io, reader: *std.Io.Reader, output: *Output) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const bytes = try reader.allocRemaining(scratch, .unlimited);
    if (bytes.len == 0) return error.MissingRequest;
    const request = try std.json.parseFromSliceLeaky(Request, scratch, bytes, .{});
    if (request.version != 1 or request.agents.len == 0) return error.InvalidProtocol;
    const input = try decodeBase64(scratch, request.input);
    const config = try decodeBase64(scratch, request.config);
    const agents = try scratch.alloc(pa.Agent, request.agents.len);
    const imports = try scratch.alloc(pa.Import, request.imports.len);
    for (imports, request.imports, 0..) |*value, wire, index| {
        if (wire.name.len == 0 or std.mem.indexOfScalar(u8, wire.name, 0) != null or
            std.mem.eql(u8, wire.name, "pa") or wire.agent == 0 or wire.agent >= agents.len) return error.InvalidImport;
        for (request.imports[0..index]) |prior| {
            if (std.mem.eql(u8, prior.name, wire.name)) return error.DuplicateImport;
        }
        value.* = .{
            .name = wire.name,
            .agent = &agents[wire.agent],
            .config = try decodeBase64(scratch, wire.config),
        };
    }
    var initialized: usize = 0;
    defer while (initialized > 0) {
        initialized -= 1;
        agents[initialized].deinit();
    };
    for (agents, request.agents) |*agent, wire| {
        var limits: pa.Limits = .{};
        if (wire.limits.memoryBytes) |memory_bytes| limits.memory_bytes = memory_bytes;
        if (wire.limits.instructions) |instructions| limits.instructions = try std.fmt.parseInt(u64, instructions, 10);
        agent.* = try pa.Agent.init(allocator, io, wire.sourceDir, wire.entryModule, limits);
        initialized += 1;
    }
    const emitter: ?pa.Emitter = if (request.emits) .{ .context = output, .write = Output.emit } else null;
    return agents[0].callWithEmitter(allocator, input, config, imports, emitter);
}

fn decodeBase64(allocator: Allocator, encoded: []const u8) ![]u8 {
    const output = try allocator.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
    try std.base64.standard.Decoder.decode(output, encoded);
    return output;
}

fn write(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeAll("\n");
    try writer.flush();
}
