const std = @import("std");
const zlua = @import("zlua");
const markdown = @import("markdown.zig");

const Allocator = std.mem.Allocator;

const File = struct {
    path: []const u8,
    source: []const u8,
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    digest: [32]u8,
    files: []const File,
};

pub const Module = struct {
    name: [:0]const u8,
    bytecode: []const u8,
};

pub const Image = struct {
    refs: std.atomic.Value(usize),
    arena: std.heap.ArenaAllocator,
    digest: [32]u8,
    modules: []const Module,

    pub fn retain(self: *Image) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *Image) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }
};

pub fn scan(allocator: Allocator, io: std.Io, source: []const u8) !Snapshot {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    var files: std.ArrayList(File) = .empty;
    const directory = try std.Io.Dir.cwd().openDir(io, source, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer directory.close(io);
    var walker = try directory.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".lua") and !std.mem.endsWith(u8, entry.path, ".md")) continue;
        try files.append(alloc, .{
            .path = try alloc.dupe(u8, entry.path),
            .source = try directory.readFileAlloc(io, entry.path, alloc, .unlimited),
        });
    }
    std.mem.sort(File, files.items, {}, struct {
        fn less(_: void, a: File, b: File) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.less);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (files.items) |file| {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(file.path.len), .little);
        hash.update(&length);
        hash.update(file.path);
        std.mem.writeInt(u64, &length, @intCast(file.source.len), .little);
        hash.update(&length);
        hash.update(file.source);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return .{ .arena = arena, .digest = digest, .files = files.items };
}

pub fn compile(allocator: Allocator, snapshot: *const Snapshot) !*Image {
    const image = try allocator.create(Image);
    errdefer allocator.destroy(image);
    image.* = .{
        .refs = .init(1),
        .arena = std.heap.ArenaAllocator.init(allocator),
        .digest = snapshot.digest,
        .modules = &.{},
    };
    errdefer image.arena.deinit();
    const alloc = image.arena.allocator();
    const compiler = try zlua.Lua.init(allocator);
    defer compiler.deinit();
    const modules = try alloc.alloc(Module, snapshot.files.len);
    for (snapshot.files, modules, 0..) |file, *module, index| {
        const extension = std.mem.lastIndexOfScalar(u8, file.path, '.').?;
        const name = try alloc.dupeZ(u8, file.path[0..extension]);
        for (name) |*byte| {
            if (byte.* == '/' or byte.* == '\\') byte.* = '.';
        }
        for (modules[0..index]) |prior| {
            if (std.mem.eql(u8, prior.name, name)) return error.DuplicateModule;
        }
        const is_markdown = std.mem.endsWith(u8, file.path, ".md");
        const source = if (is_markdown) try markdown.translate(allocator, file.source) else file.source;
        defer if (is_markdown) allocator.free(source);
        module.* = .{
            .name = name,
            .bytecode = try compileChunk(alloc, allocator, compiler, source, file.path),
        };
    }
    image.modules = modules;
    return image;
}

pub fn check(allocator: Allocator, io: std.Io, source: []const u8) !void {
    var snapshot = try scan(allocator, io, source);
    defer snapshot.arena.deinit();
    const image = try compile(allocator, &snapshot);
    image.release();
}

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
