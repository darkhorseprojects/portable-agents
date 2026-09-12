const std = @import("std");
const zlua = @import("zlua");
const capability = @import("capability.zig");
const image = @import("image.zig");
const package = @import("package.zig");
const runtime = @import("runtime.zig");

const Allocator = std.mem.Allocator;

pub const Evaluator = struct {
    allocator: Allocator,
    client: *std.http.Client,
    limits: runtime.Limits,
    image: *const image.Image,
    target: package.Target,
    self: capability.Capability,
    grants: []const capability.Grant,
    cancellation: *runtime.Cancellation,

    pub fn install(self: *Evaluator, lua: *zlua.Lua) void {
        _ = lua.getGlobal("pa");
        lua.pushLightUserdata(self);
        lua.pushClosure(zlua.wrap(dispatch), 1);
        lua.setField(-2, "eval");
        lua.pop(1);
    }

    fn dispatch(lua: *zlua.Lua) !i32 {
        const self: *Evaluator = @ptrCast(@alignCast(@constCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?)));
        const input = if (lua.getTop() >= 2) try runtime.bytes(lua, 2) else "";
        if (lua.typeOf(1) == .string) {
            const output = try self.evaluate(try runtime.bytes(lua, 1), input);
            defer self.allocator.free(output);
            _ = lua.pushString(output);
            return 1;
        }
        if (lua.typeOf(1) != .table) return error.ExpectedEvalSource;
        const count = std.math.cast(i32, lua.lenRaw(1)) orelse return error.TooManyEvalSources;
        const futures = try self.allocator.alloc(std.Io.Future(anyerror![]u8), @intCast(count));
        defer self.allocator.free(futures);
        for (1..@as(usize, @intCast(count)) + 1) |index| {
            _ = lua.getIndex(1, @intCast(index));
            _ = try runtime.bytes(lua, -1);
            lua.pop(1);
        }
        for (futures, 1..) |*future, index| {
            _ = lua.getIndex(1, @intCast(index));
            const source = runtime.bytes(lua, -1) catch unreachable;
            future.* = self.client.io.async(evaluate, .{ self, source, input });
            lua.pop(1);
        }
        for (futures) |*future| {
            if (if (self.cancellation.canceled()) future.cancel(self.client.io) else future.await(self.client.io)) |_| {} else |err| {
                if (err == error.Canceled) self.cancellation.cancel();
            }
        }
        defer for (futures) |future| if (future.result) |output| self.allocator.free(output) else |_| {};
        lua.createTable(count, 0);
        for (futures, 1..) |future, index| {
            _ = lua.pushString(try future.result);
            lua.setIndex(-2, @intCast(index));
        }
        return 1;
    }

    fn evaluate(self: *Evaluator, source: []const u8, input: []const u8) anyerror![]u8 {
        var private: package.Call = undefined;
        try private.init(self.allocator, self.client, self.limits, self.image, self.target, self.self, self.cancellation);
        defer private.deinit();
        self.install(private.vm.lua);
        const root = try private.resolve();
        var offers: std.ArrayList(Offer) = .empty;
        defer {
            for (offers.items) |offer| offer.value.deinit();
            offers.deinit(self.allocator);
        }
        var capture = Capture{ .allocator = self.allocator, .vm = &private.vm, .offers = &offers };
        private.vm.lua.pushLightUserdata(&capture);
        private.vm.lua.pushClosure(zlua.wrap(captureOffers), 1);
        private.vm.lua.pushValue(root);
        try private.vm.protect(.{ .args = 1 });
        const grants = try self.allocator.alloc(capability.Grant, try std.math.add(usize, offers.items.len, self.grants.len));
        defer self.allocator.free(grants);
        for (offers.items, grants[0..offers.items.len]) |*offer, *grant| grant.* = .{ .name = offer.name, .capability = offer.value.capability() };
        @memcpy(grants[offers.items.len..], self.grants);
        for (grants, 0..) |grant, index| {
            for (grants[0..index]) |prior| if (std.mem.eql(u8, prior.name, grant.name)) return error.DuplicateGrant;
        }
        var public = Public{ .vm = undefined, .grants = grants };
        try public.vm.init(self.allocator, self.client.io, self.limits, self.cancellation, &public);
        defer public.vm.deinit();
        public.vm.lua.pushFunction(zlua.wrap(initialize));
        try public.vm.protect(.{});
        public.vm.lua.loadBuffer(source, "eval", .text) catch return error.LuaFailure;
        _ = public.vm.lua.pushString(input);
        try public.vm.protect(.{ .args = 1, .results = 1 });
        if (self.cancellation.canceled()) return error.Canceled;
        return self.allocator.dupe(u8, try runtime.bytes(public.vm.lua, -1));
    }
};

const Offer = struct { name: []const u8, value: capability.LuaCapability };
const Capture = struct { allocator: Allocator, vm: *runtime.Vm, offers: *std.ArrayList(Offer) };

fn captureOffers(lua: *zlua.Lua) !i32 {
    const capture: *Capture = @ptrCast(@alignCast(@constCast(lua.toPointer(zlua.Lua.upvalueIndex(1)).?)));
    lua.pushNil();
    while (lua.next(1)) {
        if (lua.typeOf(-2) != .string) return error.InvalidCapabilityOffer;
        const value = try capability.LuaCapability.capture(capture.vm, -1);
        capture.offers.append(capture.allocator, .{ .name = try lua.toString(-2), .value = value }) catch |err| {
            value.deinit();
            return err;
        };
        lua.pop(1);
    }
    return 0;
}

const Public = struct {
    vm: runtime.Vm,
    grants: []const capability.Grant,
};

fn initialize(lua: *zlua.Lua) !i32 {
    lua.openBase();
    lua.openMath();
    lua.openString();
    lua.openTable();
    lua.openUtf8();
    capability.pushAgentIdFunction(lua);
    lua.setGlobal("agentid");
    try lua.loadBuffer(
        \\local preload,loaded={},{}
        \\package={preload=preload,loaded=loaded}
        \\function require(name)
        \\ if type(name)~="string" then error("invalid module name",2) end
        \\ local value=loaded[name]
        \\ if value==nil then value=preload[name] if value==nil then error("module not found: "..tostring(name),2) end loaded[name]=value end
        \\ return value
        \\end
        \\collectgarbage,dofile,getmetatable,load,loadfile,pcall,print,warn,xpcall=nil,nil,nil,nil,nil,nil,nil,nil,nil
        \\string.dump=nil
    , "eval runtime", .text);
    lua.call(.{});
    _ = lua.getGlobal("package");
    _ = lua.getField(-1, "preload");
    lua.remove(-2);
    const preload = lua.absIndex(-1);
    for (runtime.owner(Public, lua).grants) |*grant| {
        _ = lua.pushString(grant.name);
        capability.pushCapabilityProxy(lua, &grant.capability);
        lua.setTableRaw(preload);
    }
    lua.pop(1);
    return 0;
}
