const std = @import("std");
const package = @import("package.zig");
const runtime = @import("lua.zig");
const identity = @import("identity.zig");

const Allocator = std.mem.Allocator;

pub const Entry = runtime.Entry;
pub const Interface = runtime.Interface;
pub const Mount = runtime.Mount;
pub const Identity = identity.Identity;

pub const Config = struct {
    identity: ?Identity = null,
    lua_bytes: usize = 16 * 1024 * 1024,
    lua_steps: u64 = 2_000_000,
};

pub const Binding = struct {
    agent: *Agent,
    image: *const package.Image,
    entry: Entry,
    mounts: []const Mount = &.{},

    pub fn interface(self: *Binding) Interface {
        return .{ .identity = self.agent.identity, .context = self, .call = invoke };
    }

    fn invoke(pointer: *anyopaque, allocator: Allocator, input: []const u8) ![]u8 {
        const self: *Binding = @ptrCast(@alignCast(pointer));
        return self.agent.call(allocator, self.image, self.entry, input, self.mounts);
    }
};

pub const Agent = struct {
    identity: Identity,
    lua_bytes: usize,
    lua_steps: u64,
    client: std.http.Client,

    pub fn init(allocator: Allocator, io: std.Io, config: Config) Agent {
        return .{
            .identity = config.identity orelse identity.generate(io),
            .lua_bytes = config.lua_bytes,
            .lua_steps = config.lua_steps,
            .client = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *Agent) void {
        self.client.deinit();
    }

    pub fn bind(self: *Agent, image: *const package.Image, entry: Entry, mounts: []const Mount) Binding {
        return .{ .agent = self, .image = image, .entry = entry, .mounts = mounts };
    }

    pub fn call(self: *Agent, allocator: Allocator, image: *const package.Image, entry: Entry, input: []const u8, mounts: []const Mount) ![]u8 {
        for (mounts, 0..) |mount, index| {
            for (mounts[0..index]) |prior| if (std.mem.eql(u8, prior.name, mount.name)) return error.DuplicateMount;
        }
        var quota = runtime.Quota{ .child = allocator, .limit = self.lua_bytes };
        var canceled: std.atomic.Value(bool) = .init(false);
        var binding = self.bind(image, entry, mounts);
        var context = runtime.Context{
            .self = binding.interface(),
            .quota = &quota,
            .client = &self.client,
            .image = image,
            .entry = entry,
            .mounts = mounts,
            .lua_steps = self.lua_steps,
            .steps_left = self.lua_steps,
            .canceled = &canceled,
        };
        return runtime.call(&context, input);
    }
};
