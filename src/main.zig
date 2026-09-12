const std = @import("std");
const pa = @import("pa");
const protocol = @import("protocol.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3 or (!std.mem.eql(u8, args[1], "check") and !std.mem.eql(u8, args[1], "call"))) {
        std.debug.print("usage: agent check|call <source>\n", .{});
        return error.InvalidArguments;
    }
    if (std.mem.eql(u8, args[1], "check")) {
        var image = try pa.Image.init(init.gpa, init.io, args[2]);
        image.deinit();
        return;
    }
    var input_buffer: [8192]u8 = undefined;
    var input: std.Io.File.Reader = .init(.stdin(), init.io, &input_buffer);
    var output_buffer: [8192]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &output_buffer);
    try protocol.call(init.gpa, init.io, args[2], &input.interface, &output.interface);
}
