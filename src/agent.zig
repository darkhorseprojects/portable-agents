const std = @import("std");
const capability = @import("capability.zig");
const eval = @import("eval.zig");
const image = @import("image.zig");
const lua = @import("lua.zig");
const runtime = @import("runtime.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    agent_id: ?capability.AgentId = null,
    limits: lua.Limits = .{},
};

pub const Import = struct {
    name: []const u8,
    agent: *Agent,
    image: *const image.Image,
    entry: []const u8,
};

pub const Agent = struct {
    agent_id: capability.AgentId,
    io: std.Io,
    limits: lua.Limits,
    client: std.http.Client,

    pub fn init(allocator: Allocator, io: std.Io, options: Options) Agent {
        return .{
            .agent_id = options.agent_id orelse capability.generateAgentId(io),
            .io = io,
            .limits = options.limits,
            .client = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *Agent) void {
        self.client.deinit();
    }

    pub fn call(self: *Agent, allocator: Allocator, image_value: *const image.Image, entry: []const u8, input: []const u8, imports: []const Import) ![]u8 {
        var cancellation: lua.Cancellation = .{};
        var owner: runtime.Runtime = undefined;
        try owner.init(allocator, self, image_value, entry, imports, &cancellation);
        defer owner.deinit();
        eval.install(&owner);
        try owner.resolve();
        return owner.call(input);
    }
};
