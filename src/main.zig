const std = @import("std");
const pa = @import("pa");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return usage();
    if (std.mem.eql(u8, args[1], "check")) return pa.check(allocator, io, args[2]);
    if (!std.mem.eql(u8, args[1], "run") and !std.mem.eql(u8, args[1], "serve")) return usage();
    var agent = try pa.Agent.init(allocator, io, .{
        .source = args[2],
        .key = std.crypto.sign.Ed25519.KeyPair.generate(io),
    });
    defer agent.deinit();
    var input_buffer: [8192]u8 = undefined;
    var input_file: std.Io.File.Reader = .init(.stdin(), io, &input_buffer);
    const input = &input_file.interface;
    var output_buffer: [8192]u8 = undefined;
    var output_file: std.Io.File.Writer = .init(.stdout(), io, &output_buffer);
    const output = &output_file.interface;
    while (try readFrame(allocator, input)) |request| {
        {
            const invocation = agent.invoke(allocator, request, null) catch |err| {
                allocator.free(request);
                return err;
            };
            allocator.free(request);
            defer invocation.destroy(allocator);
            while (true) switch (try invocation.@"resume"()) {
                .yielded => |bytes| try writeFrame(output, 0, bytes),
                .returned => |bytes| {
                    try writeFrame(output, 1, bytes);
                    try output.flush();
                    break;
                },
            };
        }
        if (std.mem.eql(u8, args[1], "run")) break;
    }
}

fn readFrame(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    _ = reader.peekByte() catch |err| return if (err == error.EndOfStream) null else err;
    const header = try reader.takeArray(4);
    const length = std.mem.readInt(u32, header, .little);
    if (length > 64 * 1024 * 1024) return error.FrameTooLarge;
    return @as(?[]u8, try reader.readAlloc(allocator, length));
}

fn writeFrame(writer: *std.Io.Writer, kind: u8, bytes: []const u8) !void {
    if (bytes.len > std.math.maxInt(u32)) return error.FrameTooLarge;
    var header: [5]u8 = undefined;
    header[0] = kind;
    std.mem.writeInt(u32, header[1..5], @intCast(bytes.len), .little);
    try writer.writeAll(&header);
    try writer.writeAll(bytes);
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: pa check|run|serve <dir>\n", .{});
    return error.InvalidArguments;
}
