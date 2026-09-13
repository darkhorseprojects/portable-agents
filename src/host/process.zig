const std = @import("std");
const zlua = @import("zlua");
const lua_state = @import("../lua.zig");

pub fn install(lua: *zlua.Lua) void {
    lua.pushFunction(zlua.wrap(run));
    lua.setField(-2, "process");
}

fn run(lua: *zlua.Lua) !i32 {
    errdefer lua_state.control(lua).io.checkCancel() catch lua_state.control(lua).cancellation.cancel();
    if (lua.typeOf(1) != .string or lua.typeOf(2) != .table or
        (!lua.isNoneOrNil(3) and lua.typeOf(3) != .string)) return error.InvalidProcessCall;
    const executable = try lua.toString(1);
    if (!std.fs.path.isAbsolute(executable) or std.mem.indexOfScalar(u8, executable, 0) != null) return error.ExpectedAbsolutePath;
    const count = try denseLength(lua, 2);
    const argv = try lua.allocator().alloc([]const u8, try std.math.add(usize, count, 1));
    defer lua.allocator().free(argv);
    argv[0] = executable;
    for (argv[1..], 1..) |*argument, index| {
        _ = lua.getIndex(2, @intCast(index));
        argument.* = try lua.toString(-1);
        if (std.mem.indexOfScalar(u8, argument.*, 0) != null) return error.ExpectedArgv;
        lua.pop(1);
    }
    const io = lua_state.control(lua).io;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);
    const input_file = child.stdin.?;
    child.stdin = null;
    const input = if (lua.isNoneOrNil(3)) "" else try lua.toString(3);
    var sender = try io.concurrent(sendInput, .{ input_file, io, input });
    defer _ = sender.cancel(io) catch {};
    var storage: std.Io.File.MultiReader.Buffer(2) = undefined;
    var outputs: std.Io.File.MultiReader = undefined;
    outputs.init(lua.allocator(), io, storage.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer outputs.deinit();
    try outputs.fillRemaining(.none);
    try outputs.checkAnyError();
    try sender.await(io);
    const term = try child.wait(io);
    const stdout = try outputs.toOwnedSlice(0);
    defer lua.allocator().free(stdout);
    const stderr = try outputs.toOwnedSlice(1);
    defer lua.allocator().free(stderr);
    const code = switch (term) {
        .exited => |value| value,
        else => return error.AbnormalTermination,
    };
    lua.pushInteger(code);
    _ = lua.pushString(stdout);
    _ = lua.pushString(stderr);
    return 3;
}

fn sendInput(file: std.Io.File, io: std.Io, input: []const u8) !void {
    defer file.close(io);
    try file.writeStreamingAll(io, input);
}

fn denseLength(lua: *zlua.Lua, index: i32) !usize {
    const table = lua.absIndex(index);
    const length = lua.lenRaw(table);
    var entries: usize = 0;
    lua.pushNil();
    while (lua.next(table)) {
        if (lua.typeOf(-2) != .number or lua.typeOf(-1) != .string) return error.ExpectedArgv;
        const key = try lua.toInteger(-2);
        if (key < 1 or std.math.cast(usize, key) == null or @as(usize, @intCast(key)) > length) return error.ExpectedArgv;
        entries += 1;
        lua.pop(1);
    }
    if (entries != length) return error.ExpectedArgv;
    return length;
}
