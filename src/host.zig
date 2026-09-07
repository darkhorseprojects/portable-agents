const std = @import("std");
const zlua = @import("zlua");
const identity = @import("identity.zig");
pub const fs = @import("host/fs.zig");
pub const http = @import("host/http.zig");
pub const process = @import("host/process.zig");

const Allocator = std.mem.Allocator;

pub const AgentGrant = struct {
    name: []const u8,
    handle: identity.Handle,
    eval: bool = false,
};

pub const Config = struct {
    router: ?identity.Router = null,
    agents: []const AgentGrant = &.{},
    fs: []const fs.Config = &.{},
    http: []const http.Config = &.{},
    process: []const process.Config = &.{},
};

pub const Host = struct {
    arena: std.heap.ArenaAllocator,
    router: ?identity.Router,
    agents: []const AgentGrant,
    fs_grants: []fs.Grant,
    http_grants: []http.Grant,
    process_grants: []process.Grant,
    client: std.http.Client,

    pub fn init(allocator: Allocator, io: std.Io, config: Config) !Host {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const agents = try alloc.alloc(AgentGrant, config.agents.len);
        for (config.agents, agents, 0..) |source, *target, index| {
            for (config.agents[0..index]) |prior| if (std.mem.eql(u8, prior.name, source.name)) return error.DuplicateGrant;
            target.* = .{
                .name = try alloc.dupe(u8, source.name),
                .handle = source.handle,
                .eval = source.eval,
            };
            target.handle.route = try alloc.dupe(u8, source.handle.route);
        }
        const fs_grants = try alloc.alloc(fs.Grant, config.fs.len);
        var fs_count: usize = 0;
        errdefer for (fs_grants[0..fs_count]) |*grant| grant.deinit(io);
        for (config.fs, fs_grants, 0..) |source, *target, index| {
            for (config.fs[0..index]) |prior| if (std.mem.eql(u8, prior.name, source.name)) return error.DuplicateGrant;
            target.* = try .init(alloc, io, source);
            fs_count += 1;
        }
        const http_grants = try alloc.alloc(http.Grant, config.http.len);
        for (config.http, http_grants, 0..) |source, *target, index| {
            for (config.http[0..index]) |prior| if (std.mem.eql(u8, prior.name, source.name)) return error.DuplicateGrant;
            target.* = try .init(alloc, source);
        }
        const process_grants = try alloc.alloc(process.Grant, config.process.len);
        for (config.process, process_grants, 0..) |source, *target, index| {
            for (config.process[0..index]) |prior| if (std.mem.eql(u8, prior.name, source.name)) return error.DuplicateGrant;
            target.* = try .init(alloc, source);
        }
        return .{
            .arena = arena,
            .router = config.router,
            .agents = agents,
            .fs_grants = fs_grants,
            .http_grants = http_grants,
            .process_grants = process_grants,
            .client = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *Host) void {
        for (self.fs_grants) |*grant| grant.deinit(self.client.io);
        self.client.deinit();
        self.arena.deinit();
    }

    pub fn findAgent(self: *const Host, name: []const u8, eval: bool) ?*const AgentGrant {
        for (self.agents) |*grant| if (std.mem.eql(u8, grant.name, name) and (!eval or grant.eval)) return grant;
        return null;
    }

    pub fn findFs(self: *const Host, name: []const u8, eval: bool) ?*const fs.Grant {
        for (self.fs_grants) |*grant| if (std.mem.eql(u8, grant.name, name) and (!eval or grant.eval)) return grant;
        return null;
    }

    pub fn findHttp(self: *const Host, name: []const u8, eval: bool) ?*const http.Grant {
        for (self.http_grants) |*grant| if (std.mem.eql(u8, grant.name, name) and (!eval or grant.eval)) return grant;
        return null;
    }

    pub fn findProcess(self: *const Host, name: []const u8, eval: bool) ?*const process.Grant {
        for (self.process_grants) |*grant| if (std.mem.eql(u8, grant.name, name) and (!eval or grant.eval)) return grant;
        return null;
    }

    pub fn install(self: *Host, lua: *zlua.Lua, eval: bool, caller: *identity.Caller) void {
        inline for (.{ "fs", "http", "process", "agent" }, 0..) |name, kind| {
            lua.pushLightUserdata(self);
            lua.pushBoolean(eval);
            lua.pushLightUserdata(caller);
            lua.pushInteger(kind);
            lua.pushClosure(zlua.wrap(select), 4);
            lua.setField(-2, name);
        }
    }

    fn select(lua: *zlua.Lua) !i32 {
        const self: *Host = @ptrCast(@alignCast(@constCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?)));
        const eval = lua.toBoolean(zlua.Lua.upvalueIndex(2));
        const caller: *identity.Caller = @ptrCast(@alignCast(@constCast(lua.toPointer(zlua.Lua.upvalueIndex(3)).?)));
        if (lua.typeOf(1) != .string) return error.ExpectedBytes;
        const name = try lua.toString(1);
        switch (try lua.toInteger(zlua.Lua.upvalueIndex(4))) {
            0 => (self.findFs(name, eval) orelse return error.UnknownGrant).push(lua, caller),
            1 => (self.findHttp(name, eval) orelse return error.UnknownGrant).push(lua, &self.client),
            2 => (self.findProcess(name, eval) orelse return error.UnknownGrant).push(lua, caller),
            3 => try identity.pushHandle(lua, caller.allocator, (self.findAgent(name, eval) orelse return error.UnknownGrant).handle),
            else => unreachable,
        }
        return 1;
    }
};
