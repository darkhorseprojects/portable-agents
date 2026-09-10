const std = @import("std");
const zlua = @import("zlua");
const markdown = @import("markdown.zig");

const Allocator = std.mem.Allocator;

pub const Module = struct {
    name: [:0]const u8,
    bytecode: []const u8,
};

pub const Image = struct {
    arena: std.heap.ArenaAllocator,
    modules: []const Module,

    pub fn init(allocator: Allocator, io: std.Io, source: []const u8) !Image {
        var image = Image{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .modules = &.{},
        };
        errdefer image.arena.deinit();
        const output = image.arena.allocator();
        const directory = try std.Io.Dir.cwd().openDir(io, source, .{
            .iterate = true,
            .follow_symlinks = false,
        });
        defer directory.close(io);
        var walker = try directory.walk(allocator);
        defer walker.deinit();
        const compiler = try zlua.Lua.init(allocator);
        defer compiler.deinit();
        var modules: std.ArrayList(Module) = .empty;
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or
                (!std.mem.endsWith(u8, entry.path, ".lua") and !std.mem.endsWith(u8, entry.path, ".md"))) continue;
            const bytes = try directory.readFileAlloc(io, entry.path, allocator, .unlimited);
            defer allocator.free(bytes);
            const is_markdown = std.mem.endsWith(u8, entry.path, ".md");
            const source_bytes = if (is_markdown) try markdown.translate(allocator, bytes) else bytes;
            defer if (is_markdown) allocator.free(source_bytes);
            const extension = std.mem.lastIndexOfScalar(u8, entry.path, '.').?;
            const name = try output.dupeZ(u8, entry.path[0..extension]);
            for (name) |*byte| {
                if (byte.* == '/' or byte.* == '\\') byte.* = '.';
            }
            for (modules.items) |module| {
                if (std.mem.eql(u8, module.name, name)) return error.DuplicateModule;
            }
            try modules.append(output, .{
                .name = name,
                .bytecode = try compileChunk(output, allocator, compiler, source_bytes, entry.path),
            });
        }
        image.modules = modules.items;
        return image;
    }

    pub fn deinit(self: *Image) void {
        self.arena.deinit();
    }
};

fn compileChunk(output: Allocator, scratch: Allocator, lua: *zlua.Lua, source: []const u8, name: []const u8) ![]const u8 {
    const chunk_name = try scratch.dupeZ(u8, name);
    defer scratch.free(chunk_name);
    try lua.loadBuffer(source, chunk_name, .text);
    var bytes = std.Io.Writer.Allocating.init(output);
    errdefer bytes.deinit();
    try lua.dump(zlua.wrap(struct {
        fn write(_: *zlua.Lua, part: []const u8, context: *anyopaque) bool {
            const writer: *std.Io.Writer.Allocating = @ptrCast(@alignCast(context));
            writer.writer.writeAll(part) catch return false;
            return true;
        }
    }.write), &bytes, true);
    lua.pop(1);
    return bytes.toOwnedSlice();
}
