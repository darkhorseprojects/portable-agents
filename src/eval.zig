const std = @import("std");
const zlua = @import("zlua");
const lua = @import("lua.zig");
const module = @import("module.zig");
const runtime = @import("runtime.zig");

const Allocator = std.mem.Allocator;

pub fn install(owner: *runtime.Runtime) !void {
    owner.state.pushFunction(zlua.wrap(installDispatch));
    owner.state.pushLightUserdata(owner);
    try lua.protect(owner.state, .{ .args = 1 });
    for (owner.imports) |*item| try install(&item.runtime);
}

fn installDispatch(state: *zlua.Lua) !i32 {
    const owner: *runtime.Runtime = @ptrCast(@alignCast(@constCast(state.toPointer(1).?)));
    _ = state.getGlobal("require");
    _ = state.pushString("pa");
    state.call(.{ .args = 1, .results = 1 });
    state.pushLightUserdata(owner);
    state.pushClosure(zlua.wrap(dispatch), 1);
    state.setField(-2, "eval");
    state.pop(1);
    return 0;
}

fn dispatch(state: *zlua.Lua) !i32 {
    const owner: *runtime.Runtime = @ptrCast(@alignCast(@constCast(state.toPointer(zlua.Lua.upvalueIndex(1)).?)));
    if (!state.isTable(1)) return error.ExpectedEvalView;
    const input = try lua.bytes(state, 3);
    const selection = try captureSelection(state.allocator(), owner.entry.?, state, 1);
    defer state.allocator().free(selection);
    if (state.typeOf(2) == .string) {
        const output = try evaluate(owner, selection, try lua.bytes(state, 2), input);
        defer owner.quota.backing.free(output);
        _ = state.pushString(output);
        return 1;
    }
    if (!state.isTable(2)) return error.ExpectedEvalSource;
    const count = std.math.cast(i32, state.lenRaw(2)) orelse return error.TooManyEvalSources;
    const futures = try state.allocator().alloc(std.Io.Future(anyerror![]u8), @intCast(count));
    defer state.allocator().free(futures);
    for (1..@as(usize, @intCast(count)) + 1) |index| {
        _ = state.getIndex(2, @intCast(index));
        _ = try lua.bytes(state, -1);
        state.pop(1);
    }
    for (futures, 1..) |*future, index| {
        _ = state.getIndex(2, @intCast(index));
        future.* = owner.control.io.async(evaluate, .{ owner, selection, lua.bytes(state, -1) catch unreachable, input });
        state.pop(1);
    }
    for (futures) |*future| {
        if (if (owner.control.cancellation.canceled()) future.cancel(owner.control.io) else future.await(owner.control.io)) |_| {} else |err| {
            if (err == error.Canceled) owner.control.cancellation.cancel();
        }
    }
    defer for (futures) |future| if (future.result) |output| owner.quota.backing.free(output) else |_| {};
    state.createTable(count, 0);
    for (futures, 1..) |future, index| {
        _ = state.pushString(try future.result);
        state.setIndex(-2, @intCast(index));
    }
    return 1;
}

fn captureSelection(allocator: Allocator, root: module.Resolved, state: *zlua.Lua, index: i32) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);
    const view = state.absIndex(index);
    state.pushNil();
    while (state.next(view)) {
        if (state.typeOf(-2) != .string) return error.InvalidEvalView;
        const name = try state.toString(-2);
        if (!root.matches(-1, name)) return error.InvalidEvalView;
        try names.append(allocator, name);
        state.pop(1);
    }
    return names.toOwnedSlice(allocator);
}

fn evaluate(template: *runtime.Runtime, selection: []const []const u8, code: []const u8, input: []const u8) anyerror![]u8 {
    var owner: runtime.Runtime = undefined;
    try owner.initClone(template);
    defer owner.deinit();
    try install(&owner);
    try owner.resolve();
    return run(&owner, selection, code, input);
}

fn run(owner: *runtime.Runtime, selection: []const []const u8, code: []const u8, input: []const u8) ![]u8 {
    var quota = lua.Quota{ .backing = owner.quota.backing, .max_bytes = owner.limits.memory_bytes };
    const state = try zlua.Lua.init(quota.allocator());
    defer state.deinit();
    var control = lua.Control{ .io = owner.control.io, .cancellation = owner.control.cancellation, .remaining_instructions = owner.limits.instructions };
    lua.attach(state, &control);
    state.pushFunction(zlua.wrap(execute));
    state.pushLightUserdata(owner);
    state.pushLightUserdata(@ptrCast(&selection));
    state.pushLightUserdata(@ptrCast(&code));
    state.pushLightUserdata(@ptrCast(&input));
    try lua.protect(state, .{ .args = 4, .results = 1 });
    if (owner.control.cancellation.canceled()) return error.Canceled;
    return owner.quota.backing.dupe(u8, try lua.bytes(state, -1));
}

fn execute(state: *zlua.Lua) !i32 {
    const owner: *runtime.Runtime = @ptrCast(@alignCast(@constCast(state.toPointer(1).?)));
    const selection: *const []const []const u8 = @ptrCast(@alignCast(state.toPointer(2).?));
    const code: *const []const u8 = @ptrCast(@alignCast(state.toPointer(3).?));
    const input: *const []const u8 = @ptrCast(@alignCast(state.toPointer(4).?));
    state.openBase();
    state.openMath();
    state.openString();
    state.openTable();
    state.openUtf8();
    state.createTable(0, @intCast(selection.*.len));
    const self = state.absIndex(-1);
    for (selection.*) |name| {
        const function = owner.entry.?.member(name) orelse return error.InvalidEvalView;
        _ = state.pushString(name);
        module.pushProxy(state, function, &owner.config, 1);
        state.setTableRaw(self);
    }
    state.createTable(0, @intCast(owner.imports.len));
    const imports = state.absIndex(-1);
    for (owner.imports) |*item| {
        _ = state.pushString(item.name);
        module.pushModuleProxy(state, &item.runtime.entry.?, &item.runtime.config);
        state.setTableRaw(imports);
    }
    try state.loadBuffer(
        \\local imports=...
        \\local type,error,tostring=type,error,tostring
        \\string.dump=nil
        \\local env={assert=assert,error=error,ipairs=ipairs,next=next,pairs=pairs,
        \\ rawequal=rawequal,rawget=rawget,rawlen=rawlen,rawset=rawset,select=select,
        \\ tonumber=tonumber,tostring=tostring,type=type,math=math,string=string,table=table,utf8=utf8}
        \\env._G=env
        \\function env.require(name)
        \\ if type(name)~="string" then error("invalid module name",2) end
        \\ local value=imports[name]
        \\ if value==nil then error("module not found: "..tostring(name),2) end
        \\ return value
        \\end
        \\return env
    , "eval environment", .text);
    state.pushValue(imports);
    state.call(.{ .args = 1, .results = 1 });
    const environment = state.absIndex(-1);
    try state.loadBuffer(code.*, "eval", .text);
    state.pushValue(environment);
    if (state.setUpvalue(-2, 1)) |name| {
        if (!std.mem.eql(u8, name, "_ENV")) return error.InvalidEvalChunk;
    } else |_| state.pop(1);
    state.pushValue(self);
    _ = state.pushString(input.*);
    state.call(.{ .args = 2, .results = 1 });
    return 1;
}
