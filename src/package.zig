const std = @import("std");
const zlua = @import("zlua");
const capability = @import("capability.zig");
const host = @import("host.zig");
const image = @import("image.zig");
const runtime = @import("runtime.zig");

const Allocator = std.mem.Allocator;

pub const Target = struct {
    module: []const u8,
    path: []const []const u8 = &.{},
};

pub const Call = struct {
    allocator: Allocator,
    client: *std.http.Client,
    image: *const image.Image,
    target: Target,
    self: capability.Capability,
    cancellation: *runtime.Cancellation,
    vm: runtime.Vm,

    pub fn init(self: *Call, allocator: Allocator, client: *std.http.Client, limits: runtime.Limits, image_value: *const image.Image, target: Target, self_capability: capability.Capability, cancellation: *runtime.Cancellation) !void {
        self.* = .{ .allocator = allocator, .client = client, .image = image_value, .target = target, .self = self_capability, .cancellation = cancellation, .vm = undefined };
        try self.vm.init(allocator, client.io, limits, cancellation, self);
        errdefer self.vm.deinit();
        self.vm.lua.pushFunction(zlua.wrap(initialize));
        try self.vm.protect(.{});
    }

    pub fn deinit(self: *Call) void {
        self.vm.deinit();
    }

    pub fn resolve(self: *Call) !i32 {
        self.vm.lua.pushFunction(zlua.wrap(resolveCall));
        try self.vm.protect(.{ .results = 1 });
        return self.vm.lua.absIndex(-1);
    }

    pub fn invoke(self: *Call, input: []const u8) ![]u8 {
        _ = try self.resolve();
        _ = self.vm.lua.pushString(input);
        try self.vm.protect(.{ .args = 1, .results = 1 });
        if (self.cancellation.canceled()) return error.Canceled;
        return self.allocator.dupe(u8, try runtime.bytes(self.vm.lua, -1));
    }
};

fn initialize(lua: *zlua.Lua) !i32 {
    const call = runtime.owner(Call, lua);
    lua.openLibs();
    _ = lua.getField(zlua.registry_index, zlua.preload_table);
    for (call.image.modules) |module| {
        try lua.loadBuffer(module.bytecode, module.name, .binary);
        lua.setField(-2, module.name);
    }
    lua.pop(1);
    lua.createTable(0, 7);
    capability.pushMarkFunction(lua, &call.self.agent_id);
    lua.setField(-2, "_mark");
    capability.pushCapabilityProxy(lua, &call.self);
    lua.setField(-2, "_self");
    capability.pushAgentIdFunction(lua);
    lua.setField(-2, "agentid");
    try host.install(lua, &call.client.io, call.client, call.cancellation);
    lua.setGlobal("pa");
    try lua.loadBuffer(
        \\local mark,self,next,type,error,setmetatable=pa._mark,pa._self,next,type,error,setmetatable
        \\local function capability(call,offers)
        \\ if type(call)~="function" or offers~=nil and type(offers)~="table" then error("invalid capability",2) end
        \\ local value={}
        \\ for name,offer in next,offers or {} do
        \\  if type(name)~="string" or type(offer)~="function" then error("invalid capability offer",2) end
        \\  value[name]=capability(offer)
        \\ end
        \\ return mark(setmetatable(value,{__call=function(_,...) return call(...) end,__metatable=false}))
        \\end
        \\pa.capability=capability function pa.self() return self end pa._mark,pa._self=nil,nil
    , "pa", .text);
    lua.call(.{});
    return 0;
}

fn resolveCall(lua: *zlua.Lua) !i32 {
    const target = runtime.owner(Call, lua).target;
    _ = lua.getGlobal("require");
    _ = lua.pushString(target.module);
    lua.call(.{ .args = 1, .results = 1 });
    for (target.path) |name| {
        _ = lua.pushString(name);
        _ = lua.getTable(-2);
        lua.remove(-2);
    }
    _ = try capability.capabilityAgentId(lua, -1);
    return 1;
}
