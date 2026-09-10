const std = @import("std");
const zlua = @import("zlua");
const pa = @import("pa");

const ReplyResult = anyerror![]u8;
const ReplyQueue = std.Io.Queue(ReplyResult);

const Pending = struct {
    storage: [1]ReplyResult = undefined,
    queue: ReplyQueue = undefined,
    replied: bool = false,
};

const Bridge = struct {
    io: std.Io,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    mutex: std.Io.Mutex = .init,
    pending: std.AutoHashMap(u64, *Pending),
    next_request: u64 = 1,

    fn request(self: *Bridge, pending: *Pending, mount: u32, input: []const u8) !u64 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const id = self.next_request;
        if (id == std.math.maxInt(u64)) return error.RequestIdsExhausted;
        self.next_request += 1;
        try self.pending.put(id, pending);
        self.sendMount(id, mount, input) catch |err| {
            _ = self.pending.remove(id);
            return err;
        };
        return id;
    }

    fn remove(self: *Bridge, id: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        _ = self.pending.remove(id);
    }

    fn sendMount(self: *Bridge, id: u64, mount: u32, input: []const u8) !void {
        const size = try std.math.add(usize, 17, input.len);
        if (size > std.math.maxInt(u32)) return error.FrameTooLarge;
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(size), .little);
        try self.writer.writeAll(&header);
        try self.writer.writeByte(2);
        try self.writer.writeInt(u64, id, .little);
        try self.writer.writeInt(u32, mount, .little);
        try self.writer.writeInt(u32, @intCast(input.len), .little);
        try self.writer.writeAll(input);
        try self.writer.flush();
    }

    fn fail(self: *Bridge, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var values = self.pending.valueIterator();
        while (values.next()) |pending| {
            if (!pending.*.replied) pending.*.queue.putOneUncancelable(self.io, err) catch {};
        }
    }
};

const ProtocolMount = struct {
    bridge: *Bridge,
    index: u32,

    fn load(pointer: *anyopaque, lua: *zlua.Lua, _: i32) !void {
        lua.pushLightUserdata(pointer);
        lua.pushClosure(zlua.wrap(call), 1);
    }

    fn call(lua: *zlua.Lua) !i32 {
        if (lua.typeOf(1) != .string) return error.ExpectedBytes;
        const self: *ProtocolMount = @ptrCast(@alignCast(@constCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?)));
        var pending = Pending{};
        pending.queue = .init(&pending.storage);
        const id = try self.bridge.request(&pending, self.index, try lua.toString(1));
        defer self.bridge.remove(id);
        const reply = try (try pending.queue.getOne(self.bridge.io));
        defer self.bridge.pending.allocator.free(reply);
        if (reply[0] == 4) return error.MountFailure;
        var reader = std.Io.Reader.fixed(reply[9..]);
        const output = try takeBytes(&reader);
        if (reader.bufferedLen() != 0) return error.InvalidProtocol;
        _ = lua.pushString(output);
        return 1;
    }
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
        try writeResult(&output_file.interface, false, @errorName(err));
        try output_file.interface.flush();
        return;
    };
    defer allocator.free(output);
    try writeResult(&output_file.interface, true, output);
    try output_file.interface.flush();
}

fn runCall(allocator: std.mem.Allocator, io: std.Io, source: []const u8, input: *std.Io.Reader, output: *std.Io.Writer) ![]u8 {
    const request = (try readFrame(allocator, input)) orelse return error.MissingRequest;
    defer allocator.free(request);
    var reader = std.Io.Reader.fixed(request);
    if (!std.mem.eql(u8, try reader.take(2), "PA") or try reader.takeByte() != 1) return error.InvalidProtocol;
    const lua_bytes = std.math.cast(usize, try reader.takeInt(u64, .little)) orelse return error.InvalidLimits;
    const lua_steps = try reader.takeInt(u64, .little);
    const identity = (try reader.takeArray(32)).*;
    var bridge = Bridge{
        .io = io,
        .reader = input,
        .writer = output,
        .pending = .init(allocator),
    };
    defer bridge.pending.deinit();
    const mount_count = try reader.takeInt(u32, .little);
    const contexts = try allocator.alloc(ProtocolMount, mount_count);
    defer allocator.free(contexts);
    const mounts = try allocator.alloc(pa.Mount, mount_count);
    defer allocator.free(mounts);
    for (contexts, mounts, 0..) |*context, *mount, index| {
        context.* = .{ .bridge = &bridge, .index = @intCast(index) };
        mount.* = .{ .name = try takeBytes(&reader), .context = context, .load = ProtocolMount.load };
    }
    const module = try takeBytes(&reader);
    const member_count = try reader.takeInt(u32, .little);
    const members = try allocator.alloc([]const u8, member_count);
    defer allocator.free(members);
    for (members) |*member| member.* = try takeBytes(&reader);
    const call_input = try takeBytes(&reader);
    if (reader.bufferedLen() != 0) return error.InvalidProtocol;
    var image = try pa.Image.init(allocator, io, source);
    defer image.deinit();
    var agent = try pa.Agent.init(allocator, io, .{
        .identity = identity,
        .mounts = mounts,
        .lua_bytes = lua_bytes,
        .lua_steps = lua_steps,
    });
    defer agent.deinit();
    var replies = io.async(dispatch, .{&bridge});
    const result = agent.call(allocator, &image, .{ .module = module, .members = members }, call_input) catch |err| {
        _ = replies.cancel(io) catch {};
        return err;
    };
    errdefer allocator.free(result);
    _ = replies.cancel(io) catch {};
    if (bridge.pending.count() != 0) return error.PendingMounts;
    return result;
}

fn dispatch(bridge: *Bridge) !void {
    dispatchFrames(bridge) catch |err| {
        bridge.fail(err);
        return err;
    };
}

fn dispatchFrames(bridge: *Bridge) !void {
    while (try readFrame(bridge.pending.allocator, bridge.reader)) |frame| {
        var owned = true;
        defer if (owned) bridge.pending.allocator.free(frame);
        var reader = std.Io.Reader.fixed(frame);
        const tag = try reader.takeByte();
        if (tag != 3 and tag != 4) return error.InvalidProtocol;
        const id = try reader.takeInt(u64, .little);
        if (tag == 3) _ = try takeBytes(&reader);
        if (reader.bufferedLen() != 0) return error.InvalidProtocol;
        bridge.mutex.lockUncancelable(bridge.io);
        defer bridge.mutex.unlock(bridge.io);
        const pending = bridge.pending.get(id) orelse return error.UnknownRequest;
        if (pending.replied) return error.DuplicateReply;
        pending.replied = true;
        try pending.queue.putOneUncancelable(bridge.io, frame);
        owned = false;
    }
    return error.ProtocolEof;
}

fn readFrame(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    _ = reader.peekByte() catch |err| return if (err == error.EndOfStream) null else err;
    const length = std.mem.readInt(u32, try reader.takeArray(4), .little);
    return try reader.readAlloc(allocator, length);
}

fn takeBytes(reader: *std.Io.Reader) ![]const u8 {
    return reader.take(try reader.takeInt(u32, .little));
}

fn writeResult(writer: *std.Io.Writer, success: bool, bytes: []const u8) !void {
    const size = try std.math.add(usize, 5, bytes.len);
    if (size > std.math.maxInt(u32)) return error.FrameTooLarge;
    try writer.writeInt(u32, @intCast(size), .little);
    try writer.writeByte(if (success) 0 else 1);
    try writer.writeInt(u32, @intCast(bytes.len), .little);
    try writer.writeAll(bytes);
}
