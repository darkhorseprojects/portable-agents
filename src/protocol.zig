const std = @import("std");
const pa = @import("pa");

const Allocator = std.mem.Allocator;
const max_record_bytes = 64 * 1024 * 1024;

const PendingCall = struct {
    allocator: Allocator,
    event: std.Io.Event = .unset,
    result: anyerror![]u8 = undefined,
};

const Session = struct {
    io: std.Io,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    mutex: std.Io.Mutex = .init,
    pending: std.AutoHashMap(u32, *PendingCall),
    next_id: u32 = 1,
    failure: ?anyerror = null,

    fn invoke(self: *Session, allocator: Allocator, name: []const u8, input: []const u8) ![]u8 {
        var pending = PendingCall{ .allocator = allocator };
        const id = id: {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            if (self.failure) |err| return err;
            const encoded = try encodeBase64(self.pending.allocator, input);
            defer self.pending.allocator.free(encoded);
            const id = self.next_id;
            if (id == std.math.maxInt(u32)) return error.RequestIdsExhausted;
            self.next_id += 1;
            try self.pending.put(id, &pending);
            errdefer _ = self.pending.remove(id);
            try writeLine(self.writer, .{ .grant = .{ .id = id, .name = name, .input = encoded } });
            break :id id;
        };
        pending.event.wait(self.io) catch |err| {
            self.mutex.lockUncancelable(self.io);
            const removed = self.pending.remove(id);
            self.mutex.unlock(self.io);
            if (!removed) {
                pending.event.waitUncancelable(self.io);
                if (pending.result) |bytes| allocator.free(bytes) else |_| {}
            }
            return err;
        };
        return pending.result;
    }

    fn fail(self: *Session, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.failure = err;
        var values = self.pending.valueIterator();
        while (values.next()) |pending| {
            pending.*.result = err;
            pending.*.event.set(self.io);
        }
        self.pending.clearRetainingCapacity();
    }
};

const RemoteCapability = struct {
    session: *Session,
    name: []const u8,

    fn invoke(pointer: *anyopaque, allocator: Allocator, input: []const u8) ![]u8 {
        const self: *RemoteCapability = @ptrCast(@alignCast(pointer));
        return self.session.invoke(allocator, self.name, input);
    }
};

const Request = struct {
    version: u8,
    agentId: []const u8,
    luaBytes: usize,
    luaSteps: []const u8,
    grants: []const struct { name: []const u8, agentId: []const u8 } = &.{},
    target: pa.Target,
    input: []const u8,
};

pub fn call(allocator: Allocator, io: std.Io, source: []const u8, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    const output = run(allocator, io, source, reader, writer) catch |err| {
        try writeLine(writer, .{ .result = .{ .@"error" = @errorName(err) } });
        return;
    };
    defer allocator.free(output);
    const encoded = try encodeBase64(allocator, output);
    defer allocator.free(encoded);
    try writeLine(writer, .{ .result = .{ .output = encoded } });
}

fn run(allocator: Allocator, io: std.Io, source: []const u8, reader: *std.Io.Reader, writer: *std.Io.Writer) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const request = try std.json.parseFromSliceLeaky(Request, scratch, (try readLine(scratch, reader)) orelse return error.MissingRequest, .{});
    if (request.version != 1) return error.InvalidProtocol;
    var session = Session{ .io = io, .reader = reader, .writer = writer, .pending = .init(allocator) };
    defer session.pending.deinit();
    const remotes = try scratch.alloc(RemoteCapability, request.grants.len);
    const grants = try scratch.alloc(pa.Grant, request.grants.len);
    for (remotes, grants, request.grants) |*remote, *grant, wire| {
        remote.* = .{ .session = &session, .name = wire.name };
        grant.* = .{ .name = wire.name, .capability = .{ .agent_id = try decodeAgentId(wire.agentId), .context = remote, .invoke = RemoteCapability.invoke } };
    }
    var image_value = try pa.Image.init(allocator, io, source);
    defer image_value.deinit();
    var agent_value = pa.Agent.init(allocator, io, .{ .agent_id = try decodeAgentId(request.agentId), .limits = .{
        .bytes = request.luaBytes,
        .steps = try std.fmt.parseInt(u64, request.luaSteps, 10),
    } });
    defer agent_value.deinit();
    const input = try decodeBase64(scratch, request.input);
    var replies = io.async(dispatch, .{&session});
    defer _ = replies.cancel(io) catch {};
    return agent_value.call(allocator, &image_value, request.target, input, grants);
}

fn dispatch(session: *Session) anyerror!void {
    errdefer |err| session.fail(err);
    while (try readLine(session.pending.allocator, session.reader)) |line| {
        defer session.pending.allocator.free(line);
        var message = try std.json.parseFromSlice(struct {
            reply: struct { id: u32, output: ?[]const u8 = null, @"error": ?[]const u8 = null },
        }, session.pending.allocator, line, .{});
        defer message.deinit();
        const reply = message.value.reply;
        if ((reply.output == null) == (reply.@"error" == null)) return error.InvalidProtocol;
        session.mutex.lockUncancelable(session.io);
        defer session.mutex.unlock(session.io);
        const pending = (session.pending.fetchRemove(reply.id) orelse return error.UnknownRequest).value;
        pending.result = if (reply.output) |encoded| try decodeBase64(pending.allocator, encoded) else error.GrantFailure;
        pending.event.set(session.io);
    }
    return error.ProtocolEof;
}

fn readLine(allocator: Allocator, reader: *std.Io.Reader) !?[]u8 {
    var line: std.Io.Writer.Allocating = .init(allocator);
    errdefer line.deinit();
    _ = try reader.streamDelimiterLimit(&line.writer, '\n', .limited(max_record_bytes));
    _ = reader.takeByte() catch |err| switch (err) {
        error.EndOfStream => return if (line.written().len == 0) null else error.InvalidProtocol,
        else => return err,
    };
    return try line.toOwnedSlice();
}

fn encodeBase64(allocator: Allocator, bytes: []const u8) ![]u8 {
    const size = std.base64.standard.Encoder.calcSize(bytes.len);
    if (size > max_record_bytes) return error.RecordTooLarge;
    const output = try allocator.alloc(u8, size);
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

fn writeLine(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeByte('\n');
    try writer.flush();
}
