const std = @import("std");
const package = @import("package.zig");
const runtime = @import("lua.zig");
const identity = @import("identity.zig");

const Allocator = std.mem.Allocator;

pub const Entry = runtime.Entry;
pub const Mount = runtime.Mount;
pub const Identity = identity.Identity;

pub const Config = struct {
    identity: ?Identity = null,
    mounts: []const Mount = &.{},
    lua_bytes: usize = 16 * 1024 * 1024,
    lua_steps: u64 = 2_000_000,
};

pub const Agent = struct {
    arena: std.heap.ArenaAllocator,
    identity: Identity,
    mounts: []const Mount,
    lua_bytes: usize,
    lua_steps: u64,
    client: std.http.Client,

    pub fn init(allocator: Allocator, io: std.Io, config: Config) !Agent {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const mounts = try alloc.alloc(Mount, config.mounts.len);
        for (config.mounts, mounts, 0..) |mount, *copy, index| {
            for (config.mounts[0..index]) |prior| {
                if (std.mem.eql(u8, prior.name, mount.name)) return error.DuplicateMount;
            }
            copy.* = mount;
            copy.name = try alloc.dupe(u8, mount.name);
        }
        return .{
            .arena = arena,
            .identity = config.identity orelse identity.generate(io),
            .mounts = mounts,
            .lua_bytes = config.lua_bytes,
            .lua_steps = config.lua_steps,
            .client = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *Agent) void {
        self.client.deinit();
        self.arena.deinit();
    }

    pub fn call(self: *Agent, allocator: Allocator, image: *const package.Image, entry: Entry, input: []const u8) ![]u8 {
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

    fn callOpaque(pointer: *anyopaque, allocator: Allocator, image: *const package.Image, entry: Entry, input: []const u8) ![]u8 {
        const self: *Agent = @ptrCast(@alignCast(pointer));
        return self.call(allocator, image, entry, input);
    }
};
