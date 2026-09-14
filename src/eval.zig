const std = @import("std");
const zlua = @import("zlua");
const lua = @import("lua.zig");
const module = @import("module.zig");
const runtime = @import("runtime.zig");

const Allocator = std.mem.Allocator;

const EvalResult = union(enum) {
    output: []u8,
    failure: []u8,
};

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
        const result = try evaluateResult(owner, selection, try lua.bytes(state, 2), input);
        switch (result) {
            .output => |output| {
                defer owner.quota.backing.free(output);
                _ = state.pushString(output);
                return 1;
            },
            .failure => |failure| {
                _ = state.pushString(failure);
                state.raiseError();
            },
        }
    }
    if (!state.isTable(2)) return error.ExpectedEvalSource;
    const count = std.math.cast(i32, state.lenRaw(2)) orelse return error.TooManyEvalSources;
    const futures = try state.allocator().alloc(std.Io.Future(anyerror!EvalResult), @intCast(count));
    defer state.allocator().free(futures);
    for (1..@as(usize, @intCast(count)) + 1) |index| {
        _ = state.getIndex(2, @intCast(index));
        _ = try lua.bytes(state, -1);
        state.pop(1);
    }
    for (futures, 1..) |*future, index| {
        _ = state.getIndex(2, @intCast(index));
        future.* = owner.control.io.async(evaluateResult, .{ owner, selection, lua.bytes(state, -1) catch unreachable, input });
        state.pop(1);
    }
    for (futures) |*future| {
        if (if (owner.control.cancellation.canceled()) future.cancel(owner.control.io) else future.await(owner.control.io)) |_| {} else |err| {
            if (err == error.Canceled) owner.control.cancellation.cancel();
        }
    }
    defer for (futures) |future| if (future.result) |result| switch (result) {
        .output => |output| owner.quota.backing.free(output),
        .failure => |failure| owner.quota.backing.free(failure),
    } else |_| {};
    state.createTable(count, 0);
    for (futures, 1..) |future, index| {
        state.createTable(0, 1);
        switch (try future.result) {
            .output => |output| {
                _ = state.pushString(output);
                state.setField(-2, "output");
            },
            .failure => |failure| {
                _ = state.pushString(failure);
                state.setField(-2, "error");
            },
        }
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

fn evaluate(template: *runtime.Runtime, selection: []const []const u8, code: []const u8, input: []const u8) !EvalResult {
    var owner: runtime.Runtime = undefined;
    try owner.initClone(template);
    defer owner.deinit();
    try install(&owner);
    try owner.resolve();
    return run(&owner, selection, code, input);
}

fn evaluateResult(template: *runtime.Runtime, selection: []const []const u8, code: []const u8, input: []const u8) anyerror!EvalResult {
    return evaluate(template, selection, code, input) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        return .{ .failure = try template.quota.backing.dupe(u8, @errorName(err)) };
    };
}

fn run(owner: *runtime.Runtime, selection: []const []const u8, code: []const u8, input: []const u8) !EvalResult {
    var quota = lua.Quota{ .backing = owner.quota.backing, .max_bytes = owner.limits.memory_bytes };
    const state = try zlua.Lua.init(quota.allocator());
    defer state.deinit();
    var control = lua.Control{ .io = owner.control.io, .cancellation = owner.control.cancellation, .remaining_instructions = owner.limits.instructions };
    lua.attach(state, &control);
    state.pushFunction(zlua.wrap(traceback));
    const message_handler = state.getTop();
    state.pushFunction(zlua.wrap(execute));
    state.pushLightUserdata(owner);
    state.pushLightUserdata(@ptrCast(&selection));
    state.pushLightUserdata(@ptrCast(&code));
    state.pushLightUserdata(@ptrCast(&input));
    state.protectedCall(.{ .args = 4, .results = 1, .msg_handler = message_handler }) catch |err| {
        if (owner.control.cancellation.canceled()) return error.Canceled;
        const message = state.toString(-1) catch @errorName(err);
        const failure = try owner.quota.backing.dupe(u8, message[0..@min(message.len, owner.limits.memory_bytes)]);
        state.remove(message_handler);
        return .{ .failure = failure };
    };
    state.remove(message_handler);
    if (owner.control.cancellation.canceled()) return error.Canceled;
    return .{ .output = try owner.quota.backing.dupe(u8, try lua.bytes(state, -1)) };
}

fn traceback(state: *zlua.Lua) i32 {
    const message = if (state.typeOf(1) == .string) (state.toString(1) catch unreachable) else null;
    state.traceback(state, message, 1);
    return 1;
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
    state.loadBuffer(code.*, "eval", .text) catch state.raiseError();
    state.pushValue(environment);
    if (state.setUpvalue(-2, 1)) |name| {
        if (!std.mem.eql(u8, name, "_ENV")) return error.InvalidEvalChunk;
    } else |_| state.pop(1);
    state.pushValue(self);
    _ = state.pushString(input.*);
    state.call(.{ .args = 2, .results = 1 });
    return 1;
}
