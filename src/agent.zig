const std = @import("std");
const package = @import("package.zig");
const runtime = @import("lua.zig");
const identity = @import("identity.zig");

const Allocator = std.mem.Allocator;

pub const Entry = runtime.Entry;
pub const Mount = runtime.Mount;
pub const Identity = identity.Identity;

pub const Config = struct {
    source: []const u8,
    identity: ?Identity = null,
    mounts: []const Mount = &.{},
    lua_bytes: usize = 16 * 1024 * 1024,
    lua_steps: u64 = 2_000_000,
};

pub const Agent = struct {
    allocator: Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    source: []const u8,
    identity: Identity,
    mounts: []const Mount,
    lua_bytes: usize,
    lua_steps: u64,
    client: std.http.Client,
    mutex: std.Io.Mutex,
    current: *package.Image,

    pub fn init(allocator: Allocator, io: std.Io, config: Config) !Agent {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const source = try alloc.dupe(u8, config.source);
        const mounts = try alloc.alloc(Mount, config.mounts.len);
        for (config.mounts, mounts, 0..) |mount, *copy, index| {
            for (config.mounts[0..index]) |prior| {
                if (std.mem.eql(u8, prior.name, mount.name)) return error.DuplicateMount;
            }
            copy.* = mount;
            copy.name = try alloc.dupe(u8, mount.name);
        }
        var snapshot = try package.scan(allocator, io, source);
        defer snapshot.arena.deinit();
        const image = try package.compile(allocator, &snapshot);
        return .{
            .allocator = allocator,
            .io = io,
            .arena = arena,
            .source = source,
            .identity = config.identity orelse identity.generate(io),
            .mounts = mounts,
            .lua_bytes = config.lua_bytes,
            .lua_steps = config.lua_steps,
            .client = .{ .allocator = allocator, .io = io },
            .mutex = .init,
            .current = image,
        };
    }

    pub fn deinit(self: *Agent) void {
        self.current.release();
        self.client.deinit();
        self.arena.deinit();
    }

    pub fn call(self: *Agent, allocator: Allocator, entry: Entry, input: []const u8) ![]u8 {
        const image = try self.refresh();
        defer image.release();
        var quota = runtime.Quota{ .child = allocator, .limit = self.lua_bytes };
        var canceled: std.atomic.Value(bool) = .init(false);
        var context = runtime.Context{
            .agent = self,
            .call_agent = callOpaque,
            .quota = &quota,
            .client = &self.client,
            .image = image,
            .entry = entry,
            .identity = &self.identity,
            .mounts = self.mounts,
            .lua_steps = self.lua_steps,
            .steps_left = self.lua_steps,
            .canceled = &canceled,
        };
        return runtime.call(&context, input);
    }

    fn refresh(self: *Agent) !*package.Image {
        while (true) {
            try self.mutex.lock(self.io);
            const baseline = self.current.digest;
            self.mutex.unlock(self.io);
            var snapshot = try package.scan(self.allocator, self.io, self.source);
            defer snapshot.arena.deinit();
            if (std.mem.eql(u8, &baseline, &snapshot.digest)) {
                try self.mutex.lock(self.io);
                if (std.mem.eql(u8, &baseline, &self.current.digest)) {
                    self.current.retain();
                    const image = self.current;
                    self.mutex.unlock(self.io);
                    return image;
                }
                self.mutex.unlock(self.io);
                continue;
            }
            const candidate = try package.compile(self.allocator, &snapshot);
            try self.mutex.lock(self.io);
            if (!std.mem.eql(u8, &baseline, &self.current.digest)) {
                self.mutex.unlock(self.io);
                candidate.release();
                continue;
            }
            const previous = self.current;
            self.current = candidate;
            candidate.retain();
            self.mutex.unlock(self.io);
            previous.release();
            return candidate;
        }
    }

    fn callOpaque(pointer: *anyopaque, allocator: Allocator, entry: Entry, input: []const u8) ![]u8 {
        const self: *Agent = @ptrCast(@alignCast(pointer));
        return self.call(allocator, entry, input);
    }
};
