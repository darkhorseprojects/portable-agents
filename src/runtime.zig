const std = @import("std");
const zlua = @import("zlua");
const capability = @import("capability.zig");
const host = @import("host.zig");
const image = @import("image.zig");
const lua = @import("lua.zig");

const Allocator = std.mem.Allocator;

pub const Imported = struct {
    name: []const u8,
    runtime: Runtime,
};

pub const Runtime = struct {
    limits: lua.Limits,
    client: *std.http.Client,
    image: *const image.Image,
    entry: []const u8,
    agent_id: *const capability.AgentId,
    quota: lua.Quota,
    control: lua.Control,
    state: *zlua.Lua,
    imports: []Imported,
    value: capability.Resolved,
    resolved: bool,

    pub fn init(self: *Runtime, allocator: Allocator, agent: anytype, image_value: *const image.Image, entry: []const u8, imports: anytype, cancellation: *lua.Cancellation) !void {
        for (imports, 0..) |item, index| {
            for (imports[0..index]) |prior| if (std.mem.eql(u8, prior.name, item.name)) return error.DuplicateImport;
        }
        try self.open(allocator, agent.io, agent.limits, cancellation, &agent.client, image_value, entry, &agent.agent_id);
        const storage = allocator.alloc(Imported, imports.len) catch |err| {
            self.state.deinit();
            return err;
        };
        errdefer self.abort(storage);
        for (storage, imports, 0..) |*loaded, item, index| {
            loaded.name = item.name;
            try loaded.runtime.open(allocator, item.agent.io, item.agent.limits, cancellation, &item.agent.client, item.image, item.entry, &item.agent.agent_id);
            self.imports = storage[0 .. index + 1];
        }
    }

    pub fn clone(self: *Runtime, source: *const Runtime) !void {
        try self.openFrom(source);
        const storage = source.quota.child.alloc(Imported, source.imports.len) catch |err| {
            self.state.deinit();
            return err;
        };
        errdefer self.abort(storage);
        for (storage, source.imports, 0..) |*loaded, existing, index| {
            loaded.name = existing.name;
            try loaded.runtime.openFrom(&existing.runtime);
            self.imports = storage[0 .. index + 1];
        }
    }

    pub fn resolve(self: *Runtime) !void {
        for (self.imports) |*item| {
            try item.runtime.resolve();
            try self.addImport(item.name, &item.runtime.value);
        }
        self.state.pushFunction(zlua.wrap(requireEntry));
        self.state.pushLightUserdata(self);
        try lua.protect(self.state, .{ .args = 1 });
    }

    pub fn call(self: *Runtime, input: []const u8) ![]u8 {
        return lua.propagate(self.control.cancellation, self.value.call(self.quota.child, input));
    }

    pub fn deinit(self: *Runtime) void {
        if (self.resolved) self.value.deinit();
        self.state.deinit();
        var index = self.imports.len;
        while (index > 0) {
            index -= 1;
            self.imports[index].runtime.deinit();
        }
        self.quota.child.free(self.imports);
    }

    fn open(self: *Runtime, allocator: Allocator, io: std.Io, limits: lua.Limits, cancellation: *lua.Cancellation, client: *std.http.Client, image_value: *const image.Image, entry: []const u8, agent_id: *const capability.AgentId) !void {
        self.* = .{
            .limits = limits,
            .client = client,
            .image = image_value,
            .entry = entry,
            .agent_id = agent_id,
            .quota = .{ .child = allocator, .limit = limits.bytes },
            .control = .{ .io = io, .cancellation = cancellation, .steps_left = limits.steps },
            .state = undefined,
            .imports = &.{},
            .value = undefined,
            .resolved = false,
        };
        self.state = try zlua.Lua.init(self.quota.allocator());
        errdefer self.state.deinit();
        lua.attach(self.state, &self.control);
        self.state.pushFunction(zlua.wrap(initialize));
        self.state.pushLightUserdata(self);
        try lua.protect(self.state, .{ .args = 1 });
    }

    fn openFrom(self: *Runtime, source: *const Runtime) !void {
        try self.open(source.quota.child, source.control.io, source.limits, source.control.cancellation, source.client, source.image, source.entry, source.agent_id);
    }

    fn abort(self: *Runtime, storage: []Imported) void {
        var index = self.imports.len;
        while (index > 0) {
            index -= 1;
            self.imports[index].runtime.deinit();
        }
        self.quota.child.free(storage);
        self.state.deinit();
    }

    fn addImport(self: *Runtime, name: []const u8, value: *const capability.Resolved) !void {
        self.state.pushFunction(zlua.wrap(publishImport));
        self.state.pushLightUserdata(@ptrCast(&name));
        self.state.pushLightUserdata(value);
        try lua.protect(self.state, .{ .args = 2 });
    }
};

fn initialize(state: *zlua.Lua) !i32 {
    const self: *Runtime = @ptrCast(@alignCast(@constCast(state.toPointer(1).?)));
    state.openLibs();
    _ = state.getField(zlua.registry_index, zlua.preload_table);
    for (self.image.modules) |module| {
        try state.loadBuffer(module.bytecode, module.name, .binary);
        state.setField(-2, module.name);
    }
    state.pop(1);
    state.createTable(0, 6);
    capability.pushMarkFunction(state, self.agent_id);
    state.setField(-2, "_mark");
    capability.pushAgentIdFunction(state);
    state.setField(-2, "agentid");
    try host.install(state, &self.control.io, self.client, self.control.cancellation);
    state.setGlobal("pa");
    try state.loadBuffer(
        \\local mark,agentid,next,type,error,setmetatable=pa._mark,pa.agentid,next,type,error,setmetatable
        \\local function capability(call,exports)
        \\ if type(call)~="function" or exports~=nil and type(exports)~="table" then error("invalid capability",2) end
        \\ local value={}
        \\ for name,export in next,exports or {} do
        \\  if type(name)~="string" then error("invalid capability export",2) end
        \\  agentid(export) value[name]=export
        \\ end
        \\ return mark(setmetatable(value,{__call=function(_,...) return call(...) end,__metatable=false}))
        \\end
        \\pa.capability=capability pa._mark=nil
    , "pa", .text);
    state.call(.{});
    return 0;
}

fn publishImport(state: *zlua.Lua) !i32 {
    const name: *const []const u8 = @ptrCast(@alignCast(state.toPointer(1).?));
    const value: *const capability.Resolved = @ptrCast(@alignCast(state.toPointer(2).?));
    _ = state.getField(zlua.registry_index, zlua.preload_table);
    _ = state.pushString(name.*);
    _ = state.getTableRaw(-2);
    if (!state.isNil(-1)) return error.DuplicateImport;
    state.pop(1);
    _ = state.pushString(name.*);
    capability.pushLoader(state, value);
    state.setTableRaw(-3);
    state.pop(1);
    return 0;
}

fn requireEntry(state: *zlua.Lua) !i32 {
    const self: *Runtime = @ptrCast(@alignCast(@constCast(state.toPointer(1).?)));
    _ = state.getGlobal("require");
    _ = state.pushString(self.entry);
    state.call(.{ .args = 1, .results = 1 });
    self.value = try capability.Resolved.capture(state, -1);
    self.resolved = true;
    return 0;
}
