const std = @import("std");
const zlua = @import("zlua");
const package = @import("package.zig");
const lua = @import("lua.zig");
const identity = @import("identity.zig");
const host = @import("host.zig");

const Allocator = std.mem.Allocator;

pub const Config = struct {
    source: []const u8,
    entry: []const u8 = "agent",
    key: identity.KeyPair,
    route: []const u8 = "",
    reload_ns: u64 = 100 * std.time.ns_per_ms,
    lua_bytes: usize = 16 * 1024 * 1024,
    lua_steps: u64 = 2_000_000,
    frame_bytes: usize = 1024 * 1024,
    host: host.Config = .{},
};

pub const Agent = struct {
    allocator: Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    source: []const u8,
    entry: []const u8,
    key: identity.KeyPair,
    route: []const u8,
    host: host.Host,
    reload_ns: u64,
    next_check: std.Io.Timestamp,
    lua_bytes: usize,
    lua_steps: u64,
    frame_bytes: usize,
    mutex: std.Io.Mutex,
    current: *package.Image,

    pub fn init(allocator: Allocator, io: std.Io, config: Config) !Agent {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const source = try arena.allocator().dupe(u8, config.source);
        const entry = try arena.allocator().dupe(u8, config.entry);
        const route = try arena.allocator().dupe(u8, config.route);
        var host_value = try host.Host.init(allocator, io, config.host);
        errdefer host_value.deinit();
        var snapshot = try package.scan(allocator, io, source);
        defer snapshot.arena.deinit();
        const image = try package.compile(allocator, &snapshot, entry);
        const now = std.Io.Clock.boot.now(io);
        return .{
            .allocator = allocator,
            .io = io,
            .arena = arena,
            .source = source,
            .entry = entry,
            .key = config.key,
            .route = route,
            .host = host_value,
            .reload_ns = config.reload_ns,
            .next_check = now.addDuration(.{ .nanoseconds = config.reload_ns }),
            .lua_bytes = config.lua_bytes,
            .lua_steps = config.lua_steps,
            .frame_bytes = config.frame_bytes,
            .mutex = .init,
            .current = image,
        };
    }

    pub fn deinit(self: *Agent) void {
        self.current.release();
        self.host.deinit();
        self.arena.deinit();
    }

    pub fn refresh(self: *Agent) !*package.Image {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const now = std.Io.Clock.boot.now(self.io);
        if (now.nanoseconds >= self.next_check.nanoseconds) {
            self.next_check = now.addDuration(.{ .nanoseconds = self.reload_ns });
            var snapshot = try package.scan(self.allocator, self.io, self.source);
            defer snapshot.arena.deinit();
            if (!std.mem.eql(u8, &snapshot.digest, &self.current.digest)) {
                const candidate = try package.compile(self.allocator, &snapshot, self.entry);
                const previous = self.current;
                self.current = candidate;
                previous.release();
            }
        }
        self.current.retain();
        return self.current;
    }

    pub fn invoke(self: *Agent, allocator: Allocator, input: []const u8, call: ?identity.CallId) !*Invocation {
        const image = try self.refresh();
        errdefer image.release();
        const invocation = try allocator.create(Invocation);
        errdefer allocator.destroy(invocation);
        invocation.* = .{
            .agent = self,
            .image = image,
            .quota = .{ .child = allocator, .limit = self.lua_bytes },
            .lua = undefined,
            .caller = .{
                .allocator = allocator,
                .io = self.io,
                .key = &self.key,
                .router = self.host.router,
                .parent = call,
            },
            .execution = undefined,
            .entry_ref = zlua.no_ref,
            .started = false,
            .complete = false,
            .frame_bytes = self.frame_bytes,
        };
        const self_handle = try identity.issue(&self.key, self.route, self.io);
        invocation.execution = .{
            .image = image,
            .host = &self.host,
            .caller = &invocation.caller,
            .allocator = allocator,
            .io = self.io,
            .scope = .trusted,
            .steps_left = self.lua_steps,
            .lua_bytes = self.lua_bytes,
            .lua_steps = self.lua_steps,
            .self = self_handle,
        };
        invocation.lua = try lua.createTrusted(&invocation.quota, &invocation.execution);
        errdefer invocation.lua.deinit();
        invocation.entry_ref = try openEntry(invocation.lua, image, input);
        return invocation;
    }

    pub fn openCall(self: *Agent, allocator: Allocator, encoded: []const u8) !identity.Inbound {
        return identity.verifyCall(allocator, &self.key, encoded);
    }

    pub fn closeCall(self: *Agent, allocator: Allocator, call: identity.CallId, output: []const u8) ![]u8 {
        return identity.makeReturn(allocator, &self.key, call, output);
    }
};

pub const Invocation = struct {
    agent: *Agent,
    image: *package.Image,
    quota: lua.Quota,
    lua: *zlua.Lua,
    caller: identity.Caller,
    execution: lua.Exec,
    entry_ref: i32,
    started: bool,
    complete: bool,
    frame_bytes: usize,

    pub fn @"resume"(self: *Invocation) !Frame {
        if (self.complete) return error.InvocationComplete;
        _ = self.lua.getIndexRaw(zlua.registry_index, self.entry_ref);
        const thread = try self.lua.toThread(-1);
        self.lua.pop(1);
        if (self.started) thread.setTop(0);
        var results: i32 = 0;
        const status = thread.resumeThread(null, if (self.started) 0 else 1, &results) catch return lua.luaError(thread);
        self.started = true;
        if (results != 1) return error.ExpectedOneFrame;
        const value = try lua.bytes(thread, -1);
        if (value.len > self.frame_bytes) return error.FrameTooLarge;
        return switch (status) {
            .yield => .{ .yielded = value },
            .ok => blk: {
                self.complete = true;
                break :blk .{ .returned = value };
            },
        };
    }

    pub fn destroy(self: *Invocation, allocator: Allocator) void {
        self.lua.unref(zlua.registry_index, self.entry_ref);
        self.lua.deinit();
        self.image.release();
        allocator.destroy(self);
    }
};

pub const Frame = union(enum) {
    yielded: []const u8,
    returned: []const u8,
};

fn openEntry(state: *zlua.Lua, image: *const package.Image, input: []const u8) !i32 {
    const entry = image.modules[image.entry];
    try state.loadBuffer(entry.bytecode, "entry", .binary);
    state.protectedCall(.{ .results = 1 }) catch return lua.luaError(state);
    if (state.typeOf(-1) != .function) return error.ExpectedEntryFunction;
    const thread = state.newThread();
    const reference = state.ref(zlua.registry_index);
    state.xMove(thread, 1);
    _ = thread.pushString(input);
    return reference;
}
