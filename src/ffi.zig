const std = @import("std");
const zlua = @import("zlua");
const pa = @import("root.zig");

const allocator = std.heap.smp_allocator;
const Notify = *const fn (?*anyopaque, u64, usize, ?[*]const u8, usize) callconv(.c) void;

pub const Bytes = extern struct {
    pointer: ?[*]const u8,
    length: usize,
};

pub const Mount = extern struct {
    name: Bytes,
};

pub const Result = extern struct {
    pointer: ?[*]u8,
    length: usize,
    status: u32,
};

const Response = struct {
    data: []u8,
    success: bool,
};

const Request = struct {
    buffer: [1]Response,
    queue: std.Io.Queue(Response),
    replied: bool,
};

const MountContext = struct {
    owner: *ForeignAgent,
    index: usize,
};

const ForeignAgent = struct {
    io: std.Io.Threaded,
    agent: pa.Agent,
    mutex: std.Io.Mutex,
    active: usize,
    closing: bool,
    notify: Notify,
    notify_context: ?*anyopaque,
    mount_contexts: []MountContext,
    requests: std.AutoHashMap(u64, *Request),
    next_request: u64,
};

pub export fn pa_agent_open(
    source_pointer: ?[*]const u8,
    source_length: usize,
    identity_pointer: ?[*]const u8,
    mount_pointer: ?[*]const Mount,
    mount_count: usize,
    notify: ?Notify,
    notify_context: ?*anyopaque,
    lua_bytes: usize,
    lua_steps: u64,
    result: *Result,
) callconv(.c) ?*ForeignAgent {
    result.* = emptyResult();
    return openAgent(
        source_pointer,
        source_length,
        identity_pointer,
        mount_pointer,
        mount_count,
        notify,
        notify_context,
        lua_bytes,
        lua_steps,
    ) catch |err| {
        setError(result, err);
        return null;
    };
}

fn openAgent(
    source_pointer: ?[*]const u8,
    source_length: usize,
    identity_pointer: ?[*]const u8,
    mount_pointer: ?[*]const Mount,
    mount_count: usize,
    notify: ?Notify,
    notify_context: ?*anyopaque,
    lua_bytes: usize,
    lua_steps: u64,
) !*ForeignAgent {
    const source = try inputBytes(source_pointer, source_length);
    if (mount_count != 0 and notify == null) return error.MissingMountCallback;
    const foreign = try allocator.create(ForeignAgent);
    foreign.io = .init(allocator, .{});
    errdefer {
        foreign.io.deinit();
        allocator.destroy(foreign);
    }
    foreign.mount_contexts = try allocator.alloc(MountContext, mount_count);
    errdefer allocator.free(foreign.mount_contexts);
    foreign.agent = undefined;
    foreign.mutex = .init;
    foreign.active = 0;
    foreign.closing = false;
    foreign.notify = notify orelse undefined;
    foreign.notify_context = notify_context;
    foreign.requests = .init(allocator);
    errdefer foreign.requests.deinit();
    foreign.next_request = 1;
    const descriptions = try inputMounts(mount_pointer, mount_count);
    const mounts = try allocator.alloc(pa.Mount, mount_count);
    defer allocator.free(mounts);
    for (descriptions, mounts, foreign.mount_contexts, 0..) |description, *mount, *context, index| {
        context.* = .{ .owner = foreign, .index = index };
        mount.* = .{
            .name = try inputBytes(description.name.pointer, description.name.length),
            .context = context,
            .load = loadMount,
        };
    }
    const identity: ?pa.Identity = if (identity_pointer) |pointer| pointer[0..@sizeOf(pa.Identity)].* else null;
    foreign.agent = try pa.Agent.init(allocator, foreign.io.io(), .{
        .source = source,
        .identity = identity,
        .mounts = mounts,
        .lua_bytes = lua_bytes,
        .lua_steps = lua_steps,
    });
    return foreign;
}

pub export fn pa_agent_identity(foreign: *ForeignAgent, output: *[32]u8) callconv(.c) void {
    output.* = foreign.agent.identity;
}

pub export fn pa_agent_call(
    foreign: *ForeignAgent,
    module_pointer: ?[*]const u8,
    module_length: usize,
    member_pointer: ?[*]const Bytes,
    member_count: usize,
    input_pointer: ?[*]const u8,
    input_length: usize,
    result: *Result,
) callconv(.c) void {
    result.* = emptyResult();
    foreign.mutex.lockUncancelable(foreign.io.io());
    if (foreign.closing) {
        foreign.mutex.unlock(foreign.io.io());
        setError(result, error.AgentClosing);
        return;
    }
    foreign.active += 1;
    foreign.mutex.unlock(foreign.io.io());
    defer {
        foreign.mutex.lockUncancelable(foreign.io.io());
        foreign.active -= 1;
        foreign.mutex.unlock(foreign.io.io());
    }
    const descriptions = inputMembers(member_pointer, member_count) catch |err| return setError(result, err);
    const members = allocator.alloc([]const u8, member_count) catch |err| return setError(result, err);
    defer allocator.free(members);
    for (descriptions, members) |description, *member| {
        member.* = inputBytes(description.pointer, description.length) catch |err| return setError(result, err);
    }
    const module = inputBytes(module_pointer, module_length) catch |err| return setError(result, err);
    const input = inputBytes(input_pointer, input_length) catch |err| return setError(result, err);
    const output = foreign.agent.call(allocator, .{ .module = module, .members = members }, input) catch |err| return setError(result, err);
    result.* = .{ .pointer = output.ptr, .length = output.len, .status = 0 };
}

pub export fn pa_result_free(result: *Result) callconv(.c) void {
    if (result.pointer) |pointer| allocator.free(pointer[0..result.length]);
    result.* = emptyResult();
}

pub export fn pa_mount_reply(
    foreign: *ForeignAgent,
    request_id: u64,
    status: u32,
    pointer: ?[*]const u8,
    length: usize,
) callconv(.c) u32 {
    const input = inputBytes(pointer, length) catch return 1;
    const data = allocator.dupe(u8, input) catch return 1;
    foreign.mutex.lockUncancelable(foreign.io.io());
    defer foreign.mutex.unlock(foreign.io.io());
    const request = foreign.requests.get(request_id) orelse {
        allocator.free(data);
        return 3;
    };
    if (request.replied) {
        allocator.free(data);
        return 3;
    }
    request.replied = true;
    request.queue.putOneUncancelable(foreign.io.io(), .{ .data = data, .success = status == 0 }) catch {
        allocator.free(data);
        return 1;
    };
    return 0;
}

pub export fn pa_agent_close(foreign: *ForeignAgent) callconv(.c) u32 {
    foreign.mutex.lockUncancelable(foreign.io.io());
    if (foreign.closing or foreign.active != 0 or foreign.requests.count() != 0) {
        foreign.mutex.unlock(foreign.io.io());
        return 2;
    }
    foreign.closing = true;
    foreign.mutex.unlock(foreign.io.io());
    foreign.agent.deinit();
    foreign.io.deinit();
    foreign.requests.deinit();
    allocator.free(foreign.mount_contexts);
    allocator.destroy(foreign);
    return 0;
}

fn loadMount(pointer: *anyopaque, lua: *zlua.Lua, _: i32) !void {
    lua.pushLightUserdata(pointer);
    lua.pushClosure(zlua.wrap(callMount), 1);
}

fn callMount(lua: *zlua.Lua) !i32 {
    if (lua.typeOf(1) != .string) return error.ExpectedBytes;
    const context: *MountContext = @ptrCast(@alignCast(@constCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?)));
    const foreign = context.owner;
    const input = try lua.toString(1);
    const request = try allocator.create(Request);
    request.* = .{ .buffer = undefined, .queue = undefined, .replied = false };
    request.queue = .init(&request.buffer);
    foreign.mutex.lockUncancelable(foreign.io.io());
    const request_id = foreign.next_request;
    foreign.next_request +%= 1;
    foreign.requests.put(request_id, request) catch |err| {
        foreign.mutex.unlock(foreign.io.io());
        allocator.destroy(request);
        return err;
    };
    foreign.mutex.unlock(foreign.io.io());
    foreign.notify(foreign.notify_context, request_id, context.index, input.ptr, input.len);
    const response = request.queue.getOne(foreign.io.io()) catch |err| {
        foreign.mutex.lockUncancelable(foreign.io.io());
        _ = foreign.requests.fetchRemove(request_id);
        foreign.mutex.unlock(foreign.io.io());
        allocator.destroy(request);
        return err;
    };
    foreign.mutex.lockUncancelable(foreign.io.io());
    _ = foreign.requests.fetchRemove(request_id);
    foreign.mutex.unlock(foreign.io.io());
    allocator.destroy(request);
    defer allocator.free(response.data);
    if (!response.success) return error.MountFailure;
    _ = lua.pushString(response.data);
    return 1;
}

fn inputBytes(pointer: ?[*]const u8, length: usize) ![]const u8 {
    if (length == 0) return &.{};
    return (pointer orelse return error.InvalidPointer)[0..length];
}

fn inputMounts(pointer: ?[*]const Mount, count: usize) ![]const Mount {
    if (count == 0) return &.{};
    return (pointer orelse return error.InvalidPointer)[0..count];
}

fn inputMembers(pointer: ?[*]const Bytes, count: usize) ![]const Bytes {
    if (count == 0) return &.{};
    return (pointer orelse return error.InvalidPointer)[0..count];
}

fn emptyResult() Result {
    return .{ .pointer = null, .length = 0, .status = 0 };
}

fn setError(result: *Result, err: anyerror) void {
    const message = @errorName(err);
    const data = allocator.dupe(u8, message) catch {
        result.status = 1;
        return;
    };
    result.* = .{ .pointer = data.ptr, .length = data.len, .status = 1 };
}
