const std = @import("std");
const cap = @import("capability.zig");
const eval = @import("eval.zig");
const image = @import("image.zig");
const package = @import("package.zig");
const runtime = @import("runtime.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    agent_id: ?cap.AgentId = null,
    limits: runtime.Limits = .{},
};

const BindContext = struct {
    agent: *Agent,
    image: *const image.Image,
    target: package.Target,
    grants: []const cap.Grant,

    fn capability(self: *BindContext) cap.Capability {
        return .{ .agent_id = self.agent.agent_id, .context = self, .invoke = invoke };
    }

    fn invoke(pointer: *anyopaque, allocator: Allocator, input: []const u8) ![]u8 {
        const self: *BindContext = @ptrCast(@alignCast(pointer));
        return self.agent.call(allocator, self.image, self.target, input, self.grants);
    }
};

pub const Agent = struct {
    agent_id: cap.AgentId,
    limits: runtime.Limits,
    client: std.http.Client,
    bindings: std.heap.ArenaAllocator,
    binding_mutex: std.Io.Mutex = .init,

    pub fn init(allocator: Allocator, io: std.Io, options: Options) Agent {
        return .{
            .agent_id = options.agent_id orelse cap.generateAgentId(io),
            .limits = options.limits,
            .client = .{ .allocator = allocator, .io = io },
            .bindings = .init(allocator),
        };
    }

    pub fn deinit(self: *Agent) void {
        self.client.deinit();
        self.bindings.deinit();
    }

    pub fn call(self: *Agent, allocator: Allocator, image_value: *const image.Image, target: package.Target, input: []const u8, grants: []const cap.Grant) ![]u8 {
        try validateGrants(grants);
        var context = BindContext{ .agent = self, .image = image_value, .target = target, .grants = grants };
        var cancellation: runtime.Cancellation = .{};
        var evaluator = eval.Evaluator{ .allocator = allocator, .client = &self.client, .limits = self.limits, .image = image_value, .target = target, .self = context.capability(), .grants = grants, .cancellation = &cancellation };
        var call_value: package.Call = undefined;
        try call_value.init(allocator, &self.client, self.limits, image_value, target, context.capability(), &cancellation);
        defer call_value.deinit();
        evaluator.install(call_value.vm.lua);
        return call_value.invoke(input);
    }

    pub fn bind(self: *Agent, image_value: *const image.Image, target: package.Target, grants: []const cap.Grant) !cap.Capability {
        try validateGrants(grants);
        try self.binding_mutex.lock(self.client.io);
        defer self.binding_mutex.unlock(self.client.io);
        const allocator = self.bindings.allocator();
        const context = try allocator.create(BindContext);
        const path = try allocator.alloc([]const u8, target.path.len);
        for (path, target.path) |*copy, value| copy.* = try allocator.dupe(u8, value);
        const stored_grants = try allocator.alloc(cap.Grant, grants.len);
        for (stored_grants, grants) |*copy, grant| copy.* = .{
            .name = try allocator.dupe(u8, grant.name),
            .capability = grant.capability,
        };
        context.* = .{
            .agent = self,
            .image = image_value,
            .target = .{ .module = try allocator.dupe(u8, target.module), .path = path },
            .grants = stored_grants,
        };
        return context.capability();
    }
};

fn validateGrants(grants: []const cap.Grant) !void {
    for (grants, 0..) |grant, index| {
        for (grants[0..index]) |prior| if (std.mem.eql(u8, prior.name, grant.name)) return error.DuplicateGrant;
    }
}
