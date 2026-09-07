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
        errdefer for (fs_grants[0..fs_count]) |*grant| grant.deinit();
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
            target.* = try .init(alloc, io, source);
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
        for (self.fs_grants) |*grant| grant.deinit();
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

    pub fn install(self: *Host, lua: *zlua.Lua, eval: bool, caller: *const identity.Caller) void {
        const Callbacks = struct {
            fn values(state: *zlua.Lua) struct { *Host, bool, *const identity.Caller } {
                return .{
                    @ptrCast(@alignCast(@constCast(state.toPointer(zlua.Lua.upvalueIndex(1)).?))),
                    state.toBoolean(zlua.Lua.upvalueIndex(2)),
                    @ptrCast(@alignCast(state.toPointer(zlua.Lua.upvalueIndex(3)).?)),
                };
            }
            fn fsValue(state: *zlua.Lua) !i32 {
                const value = values(state);
                const grant = value[0].findFs(state.checkString(1), value[1]) orelse return error.UnknownGrant;
                grant.push(state);
                return 1;
            }
            fn httpValue(state: *zlua.Lua) !i32 {
                const value = values(state);
                const grant = value[0].findHttp(state.checkString(1), value[1]) orelse return error.UnknownGrant;
                grant.push(state, &value[0].client);
                return 1;
            }
            fn processValue(state: *zlua.Lua) !i32 {
                const value = values(state);
                const grant = value[0].findProcess(state.checkString(1), value[1]) orelse return error.UnknownGrant;
                grant.push(state);
                return 1;
            }
            fn agentValue(state: *zlua.Lua) !i32 {
                const value = values(state);
                const grant = value[0].findAgent(state.checkString(1), value[1]) orelse return error.UnknownGrant;
                try identity.pushHandle(state, grant.handle, value[2]);
                return 1;
            }
        };
        inline for (.{ .{ "fs", Callbacks.fsValue }, .{ "http", Callbacks.httpValue }, .{ "process", Callbacks.processValue }, .{ "agent", Callbacks.agentValue } }) |field| {
            lua.pushLightUserdata(self);
            lua.pushBoolean(eval);
            lua.pushLightUserdata(caller);
            lua.pushClosure(zlua.wrap(field[1]), 3);
            lua.setField(-2, field[0]);
        }
    }
};
