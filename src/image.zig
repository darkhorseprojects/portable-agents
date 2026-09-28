const std = @import("std");
const zlua = @import("zlua");
const markdown = @import("markdown.zig");

const Allocator = std.mem.Allocator;

const Module = struct {
    name: [:0]const u8,
    bytecode: []const u8,
};

pub const Image = struct {
    arena: std.heap.ArenaAllocator,
    directory: std.Io.Dir,
    native_cpath: []const u8,
    modules: []const Module,
    entry: [:0]const u8,

    pub fn init(allocator: Allocator, io: std.Io, source_dir: []const u8, entry_module: []const u8) !Image {
        if (entry_module.len == 0) return error.InvalidEntry;
        const directory = try std.Io.Dir.cwd().openDir(io, source_dir, .{ .iterate = true, .follow_symlinks = false });
        errdefer directory.close(io);
        var image = Image{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .directory = directory,
            .native_cpath = undefined,
            .modules = &.{},
            .entry = undefined,
        };
        errdefer image.arena.deinit();
        const output = image.arena.allocator();
        var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try directory.realPath(io, &path);
        const extension = if (@import("builtin").os.tag == .windows) "dll" else "so";
        image.native_cpath = try std.fmt.allocPrint(output, "{s}{c}native{c}?.{s}", .{
            path[0..length], std.fs.path.sep, std.fs.path.sep, extension,
        });
        image.entry = try output.dupeZ(u8, entry_module);
        var walker = try directory.walk(allocator);
        defer walker.deinit();
        const compiler = try zlua.Lua.init(allocator);
        defer compiler.deinit();
        var modules: std.ArrayList(Module) = .empty;
        var names: std.StringHashMapUnmanaged(void) = .empty;
        defer names.deinit(allocator);
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const extension_index = std.mem.lastIndexOfScalar(u8, entry.path, '.') orelse continue;
            const suffix = entry.path[extension_index..];
            if (!std.mem.eql(u8, suffix, ".lua") and !std.mem.eql(u8, suffix, ".md")) continue;
            var file = try directory.openFile(io, entry.path, .{
                .allow_directory = false,
                .follow_symlinks = false,
                .resolve_beneath = true,
            });
            defer file.close(io);
            if (@import("builtin").os.tag == .windows) file.flags.nonblocking = true;
            var reader = file.reader(io, &.{});
            const bytes = try reader.interface.allocRemaining(allocator, .unlimited);
            defer allocator.free(bytes);
            const is_markdown = std.mem.eql(u8, suffix, ".md");
            const source_bytes = if (is_markdown) try markdown.translate(allocator, bytes) else bytes;
            defer if (is_markdown) allocator.free(source_bytes);
            const name = try output.dupeZ(u8, entry.path[0..extension_index]);
            for (name) |*byte| {
                if (byte.* == '/' or byte.* == '\\') byte.* = '.';
            }
            if (std.mem.eql(u8, name, "pa")) return error.ReservedModule;
            if ((try names.getOrPut(allocator, name)).found_existing) return error.DuplicateModule;
            try modules.append(output, .{
                .name = name,
                .bytecode = try compileChunk(output, allocator, compiler, source_bytes, entry.path),
            });
        }
        if (!names.contains(image.entry)) return error.MissingEntry;
        image.modules = modules.items;
        return image;
    }

    pub fn deinit(self: *Image, io: std.Io) void {
        self.directory.close(io);
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
