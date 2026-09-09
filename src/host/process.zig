const std = @import("std");
const zlua = @import("zlua");

pub fn install(lua: *zlua.Lua, io: *const std.Io, canceled: *std.atomic.Value(bool)) void {
    lua.pushLightUserdata(io);
    lua.pushLightUserdata(canceled);
    lua.pushClosure(zlua.wrap(create), 2);
    lua.setField(-2, "process");
}

fn create(lua: *zlua.Lua) !i32 {
    if (lua.typeOf(1) != .string) return error.ExpectedExecutable;
    const executable = try lua.toString(1);
    if (!std.fs.path.isAbsolute(executable)) return error.ExpectedAbsolutePath;
    lua.createTable(0, 1);
    lua.pushValue(1);
    lua.pushValue(zlua.Lua.upvalueIndex(1));
    lua.pushValue(zlua.Lua.upvalueIndex(2));
    lua.pushClosure(zlua.wrap(run), 3);
    lua.setField(-2, "run");
    return 1;
}

fn run(lua: *zlua.Lua) !i32 {
    const canceled: *std.atomic.Value(bool) = @ptrCast(@alignCast(@constCast(lua.toPointer(zlua.Lua.upvalueIndex(3)).?)));
    return runValue(lua) catch |err| {
        if (err == error.Canceled) canceled.store(true, .release);
        return err;
    };
}

fn runValue(lua: *zlua.Lua) !i32 {
    if (lua.typeOf(1) != .table or (lua.getTop() >= 2 and !lua.isNil(2) and lua.typeOf(2) != .string)) return error.InvalidProcessCall;
    const count = try denseLength(lua, 1);
    const argv = try lua.allocator().alloc([]const u8, try std.math.add(usize, count, 1));
    defer lua.allocator().free(argv);
    argv[0] = try lua.toString(zlua.Lua.upvalueIndex(1));
    for (argv[1..], 1..) |*argument, index| {
        _ = lua.getIndex(1, @intCast(index));
        argument.* = try lua.toString(-1);
        lua.pop(1);
    }
    const io: *const std.Io = @ptrCast(@alignCast(lua.toPointer(zlua.Lua.upvalueIndex(2)).?));
    var child = try std.process.spawn(io.*, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io.*);
    const input_file = child.stdin.?;
    child.stdin = null;
    const input = if (lua.getTop() >= 2 and !lua.isNil(2)) try lua.toString(2) else "";
    var sender = try io.concurrent(sendInput, .{ input_file, io.*, input });
    defer _ = sender.cancel(io.*) catch {};
    var storage: std.Io.File.MultiReader.Buffer(2) = undefined;
    var outputs: std.Io.File.MultiReader = undefined;
    outputs.init(lua.allocator(), io.*, storage.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer outputs.deinit();
    try outputs.fillRemaining(.none);
    try outputs.checkAnyError();
    try sender.await(io.*);
    const term = try child.wait(io.*);
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
