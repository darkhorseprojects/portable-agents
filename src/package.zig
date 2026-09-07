const std = @import("std");
const zlua = @import("zlua");
const markdown = @import("markdown.zig");

const Allocator = std.mem.Allocator;

const File = struct {
    name: []const u8,
    source: []const u8,
    markdown: bool,
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    digest: [32]u8,
    files: []const File,
};

pub const Module = struct {
    name: []const u8,
    bytecode: []const u8,
};

pub const Image = struct {
    refs: std.atomic.Value(usize),
    arena: std.heap.ArenaAllocator,
    digest: [32]u8,
    modules: []const Module,
    entry: usize,

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
        const markdown_file = std.mem.endsWith(u8, entry.path, ".md");
        if (!markdown_file and !std.mem.endsWith(u8, entry.path, ".lua")) continue;
        const name = try alloc.dupe(u8, entry.path);
        const bytes = try directory.readFileAlloc(io, entry.path, alloc, .unlimited);
        try files.append(alloc, .{ .name = name, .source = bytes, .markdown = markdown_file });
    }
    std.mem.sort(File, files.items, {}, struct {
        fn less(_: void, a: File, b: File) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    for (files.items) |file| {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(file.name.len), .little);
        digest.update(&length);
        digest.update(file.name);
        digest.update(&.{@intFromBool(file.markdown)});
        std.mem.writeInt(u64, &length, @intCast(file.source.len), .little);
        digest.update(&length);
        digest.update(file.source);
    }
    var sum: [32]u8 = undefined;
    digest.final(&sum);
    return .{ .arena = arena, .digest = sum, .files = try files.toOwnedSlice(alloc) };
}

pub fn compile(allocator: Allocator, snapshot: *const Snapshot, entry_name: []const u8) !*Image {
    const image = try allocator.create(Image);
    errdefer allocator.destroy(image);
    image.* = .{
        .refs = .init(1),
        .arena = std.heap.ArenaAllocator.init(allocator),
        .digest = snapshot.digest,
        .modules = &.{},
        .entry = 0,
    };
    errdefer image.arena.deinit();
    const alloc = image.arena.allocator();
    const compiler = try zlua.Lua.init(allocator);
    defer compiler.deinit();
    var modules: std.ArrayList(Module) = .empty;
    for (snapshot.files) |file| {
        const extension = std.mem.lastIndexOfScalar(u8, file.name, '.').?;
        const name = try alloc.dupe(u8, file.name[0..extension]);
        for (name) |*byte| if (byte.* == '/') {
            byte.* = '.';
        };
        for (modules.items) |module_value| {
            if (std.mem.eql(u8, module_value.name, name)) return error.DuplicateModule;
        }
        const source = if (file.markdown) try markdown.translate(allocator, file.source) else file.source;
        defer if (file.markdown) allocator.free(source);
        const bytecode = try compileChunk(alloc, compiler, source, file.name);
        try modules.append(alloc, .{ .name = name, .bytecode = bytecode });
    }
    image.modules = try modules.toOwnedSlice(alloc);
    image.entry = for (image.modules, 0..) |module_value, index| {
        if (std.mem.eql(u8, module_value.name, entry_name)) break index;
    } else return error.MissingEntry;
    return image;
}

pub fn check(allocator: Allocator, io: std.Io, source: []const u8) !void {
    var snapshot = try scan(allocator, io, source);
    defer snapshot.arena.deinit();
    const image = try compile(allocator, &snapshot, "agent");
    image.release();
}

pub fn findModule(image: *const Image, name: []const u8) ?*const Module {
    for (image.modules) |*module_value| {
        if (std.mem.eql(u8, module_value.name, name)) return module_value;
    }
    return null;
}

fn compileChunk(allocator: Allocator, lua: *zlua.Lua, source: []const u8, name: []const u8) ![]const u8 {
    const chunk_name = try allocator.dupeZ(u8, name);
    try lua.loadBuffer(source, chunk_name, .text);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    const writer = struct {
        fn write(_: *zlua.Lua, part: []const u8, data: *anyopaque) bool {
            const context: *struct { list: *std.ArrayList(u8), allocator: Allocator } = @ptrCast(@alignCast(data));
            context.list.appendSlice(context.allocator, part) catch return false;
            return true;
        }
    }.write;
    var context = .{ .list = &bytes, .allocator = allocator };
    try lua.dump(zlua.wrap(writer), &context, true);
    lua.pop(1);
    return bytes.toOwnedSlice(allocator);
}
