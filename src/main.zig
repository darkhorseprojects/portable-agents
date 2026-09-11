const std = @import("std");
const pa = @import("pa");

const Pending = struct {
    allocator: std.mem.Allocator,
    event: std.Io.Event = .unset,
    result: anyerror![]u8 = undefined,
};

const Bridge = struct {
    io: std.Io,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    mutex: std.Io.Mutex = .init,
    pending: std.AutoHashMap(u32, *Pending),
    next_request: u32 = 1,
    failure: ?anyerror = null,

    fn call(self: *Bridge, allocator: std.mem.Allocator, name: []const u8, input: []const u8) ![]u8 {
        var pending = Pending{ .allocator = allocator };
        const id = id: {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            if (self.failure) |err| return err;
            const encoded = try encodeBase64(self.pending.allocator, input);
            defer self.pending.allocator.free(encoded);
            const id = self.next_request;
            if (id == std.math.maxInt(u32)) return error.RequestIdsExhausted;
            self.next_request += 1;
            try self.pending.put(id, &pending);
            errdefer _ = self.pending.remove(id);
            try writeLine(self.writer, .{ .mount = .{ .id = id, .name = name, .input = encoded } });
            break :id id;
        };
        pending.event.wait(self.io) catch |err| {
            self.mutex.lockUncancelable(self.io);
            const claimed = self.pending.remove(id);
            self.mutex.unlock(self.io);
            if (!claimed) {
                pending.event.waitUncancelable(self.io);
                if (pending.result) |bytes| allocator.free(bytes) else |_| {}
            }
            return err;
        };
        return pending.result;
    }

    fn fail(self: *Bridge, err: anyerror) void {
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

const ProtocolInterface = struct {
    bridge: *Bridge,
    name: []const u8,

    fn call(pointer: *anyopaque, allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        const self: *ProtocolInterface = @ptrCast(@alignCast(pointer));
        return self.bridge.call(allocator, self.name, input);
    }
};

const Request = struct {
    version: u8,
    identity: []const u8,
    luaBytes: usize,
    luaSteps: []const u8,
    mounts: []const struct { name: []const u8, identity: []const u8 } = &.{},
    entry: pa.Entry,
    input: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3 or (!std.mem.eql(u8, args[1], "check") and !std.mem.eql(u8, args[1], "call"))) {
        std.debug.print("usage: agent check|call <source>\n", .{});
        return error.InvalidArguments;
    }
    if (std.mem.eql(u8, args[1], "check")) {
        var image = try pa.Image.init(allocator, io, args[2]);
        image.deinit();
        return;
    }
    var input_buffer: [8192]u8 = undefined;
    var input_file: std.Io.File.Reader = .init(.stdin(), io, &input_buffer);
    var output_buffer: [8192]u8 = undefined;
    var output_file: std.Io.File.Writer = .init(.stdout(), io, &output_buffer);
    const output = runCall(allocator, io, args[2], &input_file.interface, &output_file.interface) catch |err| {
        try writeLine(&output_file.interface, .{ .result = .{ .@"error" = @errorName(err) } });
        return;
    };
    defer allocator.free(output);
    const encoded = try encodeBase64(allocator, output);
    defer allocator.free(encoded);
    try writeLine(&output_file.interface, .{ .result = .{ .output = encoded } });
}

fn runCall(allocator: std.mem.Allocator, io: std.Io, source: []const u8, input: *std.Io.Reader, output: *std.Io.Writer) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const line = (try readLine(scratch, input)) orelse return error.MissingRequest;
    const request = try std.json.parseFromSliceLeaky(Request, scratch, line, .{});
    if (request.version != 1) return error.InvalidProtocol;
    const call_input = try decodeBase64(scratch, request.input);
    var bridge = Bridge{ .io = io, .reader = input, .writer = output, .pending = .init(allocator) };
    defer bridge.pending.deinit();
    const contexts = try scratch.alloc(ProtocolInterface, request.mounts.len);
    const mounts = try scratch.alloc(pa.Mount, request.mounts.len);
    for (contexts, mounts, request.mounts) |*context, *mount, wire| {
        context.* = .{ .bridge = &bridge, .name = wire.name };
        mount.* = .{ .name = wire.name, .interface = .{
            .identity = try decodeIdentity(wire.identity),
            .context = context,
            .call = ProtocolInterface.call,
        } };
    }
    var image = try pa.Image.init(allocator, io, source);
    defer image.deinit();
    var agent = pa.Agent.init(allocator, io, .{
        .identity = try decodeIdentity(request.identity),
        .lua_bytes = request.luaBytes,
        .lua_steps = try std.fmt.parseInt(u64, request.luaSteps, 10),
    });
    defer agent.deinit();
    var replies = io.async(dispatch, .{&bridge});
    defer _ = replies.cancel(io) catch {};
    return agent.call(allocator, &image, request.entry, call_input, mounts);
}

fn dispatch(bridge: *Bridge) anyerror!void {
    errdefer |err| bridge.fail(err);
    while (try readLine(bridge.pending.allocator, bridge.reader)) |line| {
        defer bridge.pending.allocator.free(line);
        var message = try std.json.parseFromSlice(struct {
            reply: struct { id: u32, output: ?[]const u8 = null, @"error": ?[]const u8 = null },
        }, bridge.pending.allocator, line, .{});
        defer message.deinit();
        const reply = message.value.reply;
        if ((reply.output == null) == (reply.@"error" == null)) return error.InvalidProtocol;
        bridge.mutex.lockUncancelable(bridge.io);
        defer bridge.mutex.unlock(bridge.io);
        const pending = bridge.pending.get(reply.id) orelse return error.UnknownRequest;
        pending.result = if (reply.output) |encoded| try decodeBase64(pending.allocator, encoded) else error.MountFailure;
        _ = bridge.pending.remove(reply.id);
        pending.event.set(bridge.io);
    }
    return error.ProtocolEof;
}

fn readLine(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    var line: std.Io.Writer.Allocating = .init(allocator);
    errdefer line.deinit();
    _ = reader.streamDelimiter(&line.writer, '\n') catch |err| switch (err) {
        error.EndOfStream => return if (line.written().len == 0) null else error.InvalidProtocol,
        else => return err,
    };
    reader.toss(1);
    return try line.toOwnedSlice();
}

fn encodeBase64(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const output = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    return @constCast(std.base64.standard.Encoder.encode(output, bytes));
}

fn decodeIdentity(encoded: []const u8) !pa.Identity {
    var value: pa.Identity = undefined;
    if (try std.base64.standard.Decoder.calcSizeForSlice(encoded) != value.len) return error.InvalidIdentity;
    try std.base64.standard.Decoder.decode(&value, encoded);
    return value;
}

fn decodeBase64(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
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
