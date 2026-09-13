const std = @import("std");
const zlua = @import("zlua");
const host = @import("host.zig");
const Image = @import("image.zig").Image;
const lua = @import("lua.zig");
const module = @import("module.zig");

const Allocator = std.mem.Allocator;

const LoadedImport = struct {
    name: []const u8,
    runtime: Runtime,
};

pub const Runtime = struct {
    limits: lua.Limits,
    client: *std.http.Client,
    image: *const Image,
    config: []const u8,
    quota: lua.Quota,
    control: lua.Control,
    state: *zlua.Lua,
    imports: []LoadedImport,
    entry: ?module.Resolved,

    pub fn init(self: *Runtime, allocator: Allocator, agent: anytype, config: []const u8, imports: anytype, cancellation: *lua.Cancellation) !void {
        try self.open(allocator, agent.client.io, agent.limits, cancellation, &agent.client, &agent.image, config);
        const storage = allocator.alloc(LoadedImport, imports.len) catch |err| {
            self.state.deinit();
            return err;
        };
        errdefer self.abort(storage);
        for (storage, imports, 0..) |*loaded, item, index| {
            loaded.name = item.name;
            try loaded.runtime.open(allocator, item.agent.client.io, item.agent.limits, cancellation, &item.agent.client, &item.agent.image, item.config);
            self.imports = storage[0 .. index + 1];
        }
    }

    pub fn initClone(self: *Runtime, template: *const Runtime) !void {
        try self.openFrom(template);
        const storage = template.quota.backing.alloc(LoadedImport, template.imports.len) catch |err| {
            self.state.deinit();
            return err;
        };
        errdefer self.abort(storage);
        for (storage, template.imports, 0..) |*loaded, existing, index| {
            loaded.name = existing.name;
            try loaded.runtime.openFrom(&existing.runtime);
            self.imports = storage[0 .. index + 1];
        }
    }

    pub fn resolve(self: *Runtime) !void {
        for (self.imports) |*item| {
            try item.runtime.resolve();
            self.state.pushFunction(zlua.wrap(publishImport));
            self.state.pushLightUserdata(@ptrCast(&item.name));
            self.state.pushLightUserdata(&item.runtime.entry.?);
            self.state.pushLightUserdata(@ptrCast(&item.runtime.config));
            try lua.protect(self.state, .{ .args = 3 });
        }
        self.state.pushFunction(zlua.wrap(requireEntry));
        self.state.pushLightUserdata(self);
        try lua.protect(self.state, .{ .args = 1 });
    }

    pub fn call(self: *Runtime, input: []const u8) ![]u8 {
        return self.entry.?.callable.call(self.quota.backing, input, self.config);
    }

    pub fn deinit(self: *Runtime) void {
        if (self.entry) |entry| entry.deinit(self.state.allocator());
        self.state.deinit();
        var index = self.imports.len;
        while (index > 0) {
            index -= 1;
            self.imports[index].runtime.deinit();
        }
        self.quota.backing.free(self.imports);
    }

    fn open(self: *Runtime, allocator: Allocator, io: std.Io, limits: lua.Limits, cancellation: *lua.Cancellation, client: *std.http.Client, image: *const Image, config: []const u8) !void {
        self.* = .{
            .limits = limits,
            .client = client,
            .image = image,
            .config = config,
            .quota = .{ .backing = allocator, .max_bytes = limits.memory_bytes },
            .control = .{ .io = io, .cancellation = cancellation, .remaining_instructions = limits.instructions },
            .state = undefined,
            .imports = &.{},
            .entry = null,
        };
        self.state = try zlua.Lua.init(self.quota.allocator());
        errdefer self.state.deinit();
        lua.attach(self.state, &self.control);
        self.state.pushFunction(zlua.wrap(initialize));
        self.state.pushLightUserdata(self);
        try lua.protect(self.state, .{ .args = 1 });
    }

    fn openFrom(self: *Runtime, source: *const Runtime) !void {
        try self.open(source.quota.backing, source.control.io, source.limits, source.control.cancellation, source.client, source.image, source.config);
    }

    fn abort(self: *Runtime, storage: []LoadedImport) void {
        var index = self.imports.len;
        while (index > 0) {
            index -= 1;
            self.imports[index].runtime.deinit();
        }
        self.quota.backing.free(storage);
        self.state.deinit();
    }
};

fn initialize(state: *zlua.Lua) !i32 {
    const self: *Runtime = @ptrCast(@alignCast(@constCast(state.toPointer(1).?)));
    state.openLibs();
    _ = state.getField(zlua.registry_index, zlua.preload_table);
    for (self.image.modules) |item| {
        try state.loadBuffer(item.bytecode, item.name, .binary);
        state.setField(-2, item.name);
    }
    state.pop(1);
    state.createTable(0, 5);
    try host.install(state, self.client);
    try state.loadBuffer(
        \\local pa=...
        \\local type,error,next,setmetatable,require=type,error,next,setmetatable,require
        \\local function readonly(value)
        \\ if type(value)~="table" then return value end
        \\ local data={}
        \\ for key,item in next,value do data[key]=readonly(item) end
        \\ return setmetatable({}, {
        \\  __index=data,
        \\  __newindex=function() error("immutable document",2) end,
        \\  __len=function() return #data end,
        \\  __pairs=function() return next,data,nil end,
        \\  __metatable=false,
        \\ })
        \\end
        \\local function bindDocument(project)
        \\ if type(project)~="function" then error("invalid document",2) end
        \\ local value={} project(value) value=readonly(value)
        \\ local module_pa=setmetatable({document=function() return value end},{__index=pa,__metatable=false})
        \\ return function(name)
        \\  if name=="pa" then return module_pa end
        \\  return require(name)
        \\ end
        \\end
        \\pa.document=function() error("document unavailable",2) end
        \\pa._bindDocument=bindDocument
        \\package.preload.pa=function() return pa end
    , "pa", .text);
    state.pushValue(-2);
    state.call(.{ .args = 1 });
    state.pop(1);
    return 0;
}

fn publishImport(state: *zlua.Lua) !i32 {
    const name: *const []const u8 = @ptrCast(@alignCast(state.toPointer(1).?));
    const value: *const module.Resolved = @ptrCast(@alignCast(state.toPointer(2).?));
    const config: *const []const u8 = @ptrCast(@alignCast(state.toPointer(3).?));
    _ = state.getField(zlua.registry_index, zlua.preload_table);
    _ = state.pushString(name.*);
    _ = state.getTableRaw(-2);
    if (!state.isNil(-1)) return error.DuplicateImport;
    state.pop(1);
    _ = state.pushString(name.*);
    module.pushLoader(state, value, config);
    state.setTableRaw(-3);
    state.pop(1);
    return 0;
}

fn requireEntry(state: *zlua.Lua) !i32 {
    const self: *Runtime = @ptrCast(@alignCast(@constCast(state.toPointer(1).?)));
    _ = state.getGlobal("require");
    _ = state.pushString(self.image.entry);
    state.call(.{ .args = 1, .results = 1 });
    self.entry = try module.Resolved.capture(state.allocator(), state, -1);
    return 0;
}
