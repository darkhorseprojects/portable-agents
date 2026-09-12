const std = @import("std");
const zlua = @import("zlua");
const capability = @import("capability.zig");
const lua = @import("lua.zig");
const runtime = @import("runtime.zig");

pub fn install(owner: *runtime.Runtime) !void {
    owner.state.pushFunction(zlua.wrap(installDispatch));
    owner.state.pushLightUserdata(owner);
    try lua.protect(owner.state, .{ .args = 1 });
    for (owner.imports) |*item| try install(&item.runtime);
}

fn installDispatch(state: *zlua.Lua) !i32 {
    const owner: *runtime.Runtime = @ptrCast(@alignCast(@constCast(state.toPointer(1).?)));
    _ = state.getGlobal("pa");
    state.pushLightUserdata(owner);
    state.pushClosure(zlua.wrap(dispatch), 1);
    state.setField(-2, "eval");
    state.pop(1);
    return 0;
}

fn dispatch(state: *zlua.Lua) !i32 {
    const owner: *runtime.Runtime = @ptrCast(@alignCast(@constCast(state.toPointer(zlua.Lua.upvalueIndex(1)).?)));
    const input = if (state.getTop() >= 2) try lua.bytes(state, 2) else "";
    if (state.typeOf(1) == .string) {
        const output = try evaluate(owner, try lua.bytes(state, 1), input);
        defer owner.quota.child.free(output);
        _ = state.pushString(output);
        return 1;
    }
    if (state.typeOf(1) != .table) return error.ExpectedEvalSource;
    const count = std.math.cast(i32, state.lenRaw(1)) orelse return error.TooManyEvalSources;
    const futures = try state.allocator().alloc(std.Io.Future(anyerror![]u8), @intCast(count));
    defer state.allocator().free(futures);
    for (1..@as(usize, @intCast(count)) + 1) |index| {
        _ = state.getIndex(1, @intCast(index));
        _ = try lua.bytes(state, -1);
        state.pop(1);
    }
    for (futures, 1..) |*future, index| {
        _ = state.getIndex(1, @intCast(index));
        future.* = owner.control.io.async(evaluate, .{ owner, lua.bytes(state, -1) catch unreachable, input });
        state.pop(1);
    }
    for (futures) |*future| {
        if (if (owner.control.cancellation.canceled()) future.cancel(owner.control.io) else future.await(owner.control.io)) |_| {} else |err| {
            if (err == error.Canceled) owner.control.cancellation.cancel();
        }
    }
    defer for (futures) |future| if (future.result) |output| owner.quota.child.free(output) else |_| {};
    state.createTable(count, 0);
    for (futures, 1..) |future, index| {
        _ = state.pushString(try future.result);
        state.setIndex(-2, @intCast(index));
    }
    return 1;
}

fn evaluate(source: *runtime.Runtime, code: []const u8, input: []const u8) anyerror![]u8 {
    var owner: runtime.Runtime = undefined;
    try owner.clone(source);
    defer owner.deinit();
    try install(&owner);
    try owner.resolve();
    const allocator = owner.state.allocator();
    const exports = try capability.captureExports(allocator, owner.value);
    defer capability.freeExports(allocator, exports);
    return run(&owner, exports, code, input);
}

fn run(owner: *runtime.Runtime, exports: []const capability.Export, source: []const u8, input: []const u8) ![]u8 {
    for (exports) |left| for (owner.imports) |right| {
        if (std.mem.eql(u8, left.name, right.name)) return error.DuplicateImport;
    };
    var quota = lua.Quota{ .child = owner.quota.child, .limit = owner.limits.bytes };
    const state = try zlua.Lua.init(quota.allocator());
    defer state.deinit();
    var control = lua.Control{ .io = owner.control.io, .cancellation = owner.control.cancellation, .steps_left = owner.limits.steps };
    lua.attach(state, &control);
    state.pushFunction(zlua.wrap(execute));
    state.pushLightUserdata(owner);
    state.pushLightUserdata(@ptrCast(&exports));
    state.pushLightUserdata(@ptrCast(&source));
    state.pushLightUserdata(@ptrCast(&input));
    try lua.protect(state, .{ .args = 4, .results = 1 });
    if (owner.control.cancellation.canceled()) return error.Canceled;
    return owner.quota.child.dupe(u8, try lua.bytes(state, -1));
}

fn execute(state: *zlua.Lua) !i32 {
    const owner: *runtime.Runtime = @ptrCast(@alignCast(@constCast(state.toPointer(1).?)));
    const exports: *const []const capability.Export = @ptrCast(@alignCast(state.toPointer(2).?));
    const source: *const []const u8 = @ptrCast(@alignCast(state.toPointer(3).?));
    const input: *const []const u8 = @ptrCast(@alignCast(state.toPointer(4).?));
    state.openBase();
    state.openMath();
    state.openString();
    state.openTable();
    state.openUtf8();
    capability.pushAgentIdFunction(state);
    state.setGlobal("agentid");
    try state.loadBuffer(
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
    state.call(.{});
    _ = state.getGlobal("package");
    _ = state.getField(-1, "preload");
    state.remove(-2);
    const preload = state.absIndex(-1);
    for (exports.*) |*item| {
        _ = state.pushString(item.name);
        capability.pushProxy(state, &item.value);
        state.setTableRaw(preload);
    }
    for (owner.imports) |*item| {
        _ = state.pushString(item.name);
        capability.pushProxy(state, &item.runtime.value);
        state.setTableRaw(preload);
    }
    state.pop(1);
    try state.loadBuffer(source.*, "eval", .text);
    _ = state.pushString(input.*);
    state.call(.{ .args = 1, .results = 1 });
    return 1;
}
