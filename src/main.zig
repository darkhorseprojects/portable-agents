const std = @import("std");
const pa = @import("pa");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return usage();
    if (std.mem.eql(u8, args[1], "check")) return pa.check(allocator, io, args[2]);
    if (!std.mem.eql(u8, args[1], "serve")) return usage();
    var agent = try pa.Agent.init(allocator, io, .{ .source = args[2] });
    defer agent.deinit();
    var input_buffer: [8192]u8 = undefined;
    var input_file: std.Io.File.Reader = .init(.stdin(), io, &input_buffer);
    var output_buffer: [8192]u8 = undefined;
    var output_file: std.Io.File.Writer = .init(.stdout(), io, &output_buffer);
    while (try readFrame(allocator, &input_file.interface)) |request| {
        const response = agent.call(allocator, .{ .module = "agent" }, request) catch |err| {
            allocator.free(request);
            return err;
        };
        allocator.free(request);
        defer allocator.free(response);
        try writeFrame(&output_file.interface, response);
        try output_file.interface.flush();
    }
}

fn readFrame(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    _ = reader.peekByte() catch |err| return if (err == error.EndOfStream) null else err;
    const header = try reader.takeArray(4);
    return @as(?[]u8, try reader.readAlloc(allocator, std.mem.readInt(u32, header, .little)));
}

fn writeFrame(writer: *std.Io.Writer, bytes: []const u8) !void {
    if (bytes.len > std.math.maxInt(u32)) return error.FrameTooLarge;
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(bytes.len), .little);
    try writer.writeAll(&header);
    try writer.writeAll(bytes);
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: agent check|serve <source>\n", .{});
    return error.InvalidArguments;
}
