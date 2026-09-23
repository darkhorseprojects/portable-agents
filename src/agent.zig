const std = @import("std");
const eval = @import("eval.zig");
const Image = @import("image.zig").Image;
const lua = @import("lua.zig");
const runtime = @import("runtime.zig");

const Allocator = std.mem.Allocator;

pub const Import = struct {
    name: []const u8,
    agent: *Agent,
    config: []const u8,
};

pub const Agent = struct {
    limits: lua.Limits,
    client: std.http.Client,
    image: Image,

    pub fn init(allocator: Allocator, io: std.Io, source_dir: []const u8, entry_module: []const u8, limits: lua.Limits) !Agent {
        if (source_dir.len == 0 or limits.memory_bytes == 0 or limits.instructions == 0) return error.InvalidOptions;
        return .{
            .limits = limits,
            .client = .{ .allocator = allocator, .io = io },
            .image = try .init(allocator, io, source_dir, entry_module),
        };
    }

    pub fn deinit(self: *Agent) void {
        self.image.deinit(self.client.io);
        self.client.deinit();
    }

    pub fn call(self: *Agent, allocator: Allocator, input: []const u8, config: []const u8, imports: []const Import) ![]u8 {
        return self.callWithEvents(allocator, input, config, imports, false, null);
    }

    pub fn callWithEvents(self: *Agent, allocator: Allocator, input: []const u8, config: []const u8, imports: []const Import, emits: bool, sink: ?lua.EventSink) ![]u8 {
        for (imports) |item| if (item.agent == self) return error.LocalImport;
        var cancellation: lua.Cancellation = .{};
        var owner: runtime.Runtime = undefined;
        try owner.init(allocator, self, config, imports, &cancellation, emits, sink);
        defer owner.deinit();
        try eval.install(&owner);
        try owner.resolve();
        return owner.call(input);
    }
};
