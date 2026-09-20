const std = @import("std");
const zlua = @import("zlua");
const lua = @import("lua.zig");
const module = @import("module.zig");
const runtime = @import("runtime.zig");

const EvalResult = struct {
    ok: bool,
    value: []u8,
};

pub fn install(owner: *runtime.Runtime) !void {
    owner.state.pushFunction(zlua.wrap(publish));
    owner.state.pushLightUserdata(owner);
    try lua.protect(owner.state, .{ .args = 1 });
    for (owner.imports.items) |*item| try install(&item.runtime);
}

fn publish(state: *zlua.Lua) !i32 {
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
    var selected: std.ArrayList(usize) = .empty;
    defer selected.deinit(state.allocator());
    const view = state.absIndex(1);
    state.pushNil();
    while (state.next(view)) {
        if (state.typeOf(-2) != .string) return error.InvalidEvalView;
        const member = owner.entry.?.select(-1, try state.toString(-2)) orelse return error.InvalidEvalView;
        try selected.append(state.allocator(), member);
        state.pop(1);
    }
    if (!state.isTable(2)) return error.ExpectedEvalSources;
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
        future.* = owner.control.io.async(evaluate, .{ owner, selected.items, lua.bytes(state, -1) catch unreachable, input });
        state.pop(1);
    }
    for (futures) |*future| {
        if (if (owner.control.cancellation.canceled()) future.cancel(owner.control.io) else future.await(owner.control.io)) |_| {} else |err| {
            if (err == error.Canceled) owner.control.cancellation.cancel();
        }
    }
    defer for (futures) |future| if (future.result) |result| owner.quota.backing.free(result.value) else |_| {};
    state.createTable(count, 0);
    for (futures, 1..) |future, index| {
        const result = try future.result;
        state.createTable(2, 0);
        state.pushBoolean(result.ok);
        state.setIndex(-2, 1);
        _ = state.pushString(result.value);
        state.setIndex(-2, 2);
        state.setIndex(-2, @intCast(index));
    }
    return 1;
}

fn evaluate(template: *runtime.Runtime, selection: []const usize, code: []const u8, input: []const u8) anyerror!EvalResult {
    var owner: runtime.Runtime = undefined;
    try owner.initClone(template);
    defer owner.deinit();
    try install(&owner);
    try owner.resolve();

    var quota = lua.Quota{ .backing = owner.quota.backing, .max_bytes = owner.limits.memory_bytes };
    const state = try zlua.Lua.init(quota.allocator());
    defer state.deinit();
    var control = lua.Control{ .io = owner.control.io, .cancellation = owner.control.cancellation, .remaining_instructions = owner.limits.instructions };
    lua.attach(state, &control);
    state.openBase();
    state.openMath();
    state.openString();
    state.openTable();
    state.openUtf8();
    state.createTable(0, @intCast(selection.len));
    const self = state.absIndex(-1);
    for (selection) |index| {
        const member = &owner.entry.?.members[index];
        _ = state.pushString(member.name);
        module.pushNativeProxy(state, &member.callable, &owner.config);
        state.setTableRaw(self);
    }
    state.createTable(0, @intCast(owner.imports.items.len));
    const imports = state.absIndex(-1);
    for (owner.imports.items) |*item| {
        _ = state.pushString(item.name);
        module.pushModuleProxy(state, &item.runtime.entry.?, &item.runtime.config);
        state.setTableRaw(imports);
    }
    try state.loadBuffer(
        \\local imports=...
        \\local type,error,tostring,setmetatable=type,error,tostring,setmetatable
        \\string.dump=nil
        \\local function callable(value,call)
        \\ return setmetatable(value,{__call=call,__metatable=false})
        \\end
        \\local env={assert=assert,callable=callable,error=error,ipairs=ipairs,next=next,pairs=pairs,
        \\ rawequal=rawequal,rawget=rawget,rawlen=rawlen,rawset=rawset,select=select,
        \\ tonumber=tonumber,tostring=tostring,type=type,math=math,string=string,table=table,utf8=utf8}
        \\env._G=env
        \\function env.require(name)
        \\ if type(name)~="string" then error("invalid module name",2) end
        \\ local value=imports[name]
        \\ if value==nil then error("module not found: "..tostring(name),2) end
        \\ return value
        \\end
        \\local function text(item,nested)
        \\ local kind=type(item)
        \\ if kind=="string" then return nested and string.format("%q",item) or item end
        \\ if kind~="table" then return tostring(item) end
        \\ local size,array=#item,true
        \\ for key in pairs(item) do array=array and math.type(key)=="integer" and key>=1 and key<=size end
        \\ local result={}
        \\ if array then
        \\  for index=1,size do result[index]=text(item[index],true) end
        \\ else
        \\  local keys={}
        \\  for key in pairs(item) do
        \\   assert(type(key)=="string","unsupported result key")
        \\   keys[#keys+1]=key
        \\  end
        \\  table.sort(keys)
        \\  for _,key in ipairs(keys) do result[#result+1]=key.."="..text(item[key],true) end
        \\ end
        \\ return "{"..table.concat(result,",").."}"
        \\end
        \\return env,text
    , "eval environment", .text);
    state.pushValue(imports);
    try lua.protect(state, .{ .args = 1, .results = 2 });
    const environment = state.absIndex(-2);
    const format = state.absIndex(-1);
    state.pushFunction(zlua.wrap(lua.traceback));
    const message_handler = state.getTop();
    state.loadBuffer(code, "eval", .text) catch |err| {
        if (owner.control.cancellation.canceled()) return error.Canceled;
        if (err != error.LuaSyntax) return err;
        return .{ .ok = false, .value = try owner.quota.backing.dupe(u8, state.toString(-1) catch unreachable) };
    };
    state.pushValue(environment);
    if (state.setUpvalue(-2, 1)) |name| {
        if (!std.mem.eql(u8, name, "_ENV")) return error.InvalidEvalChunk;
    } else |_| state.pop(1);
    state.pushValue(self);
    _ = state.pushString(input);
    state.protectedCall(.{ .args = 2, .results = 1, .msg_handler = message_handler }) catch |err| {
        if (owner.control.cancellation.canceled()) return error.Canceled;
        if (err != error.LuaRuntime) return err;
        return .{ .ok = false, .value = try owner.quota.backing.dupe(u8, state.toString(-1) catch unreachable) };
    };
    if (state.typeOf(-1) != .string) {
        state.pushValue(format);
        state.pushValue(-2);
        state.protectedCall(.{ .args = 1, .results = 1, .msg_handler = message_handler }) catch |err| {
            if (owner.control.cancellation.canceled()) return error.Canceled;
            if (err != error.LuaRuntime) return err;
            return .{ .ok = false, .value = try owner.quota.backing.dupe(u8, state.toString(-1) catch unreachable) };
        };
        state.remove(-2);
    }
    return .{ .ok = true, .value = try owner.quota.backing.dupe(u8, try lua.bytes(state, -1)) };
}
