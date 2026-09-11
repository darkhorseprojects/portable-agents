const std = @import("std");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Cursor = struct {
    source: []const u8,
    offset: usize = 0,

    fn next(self: *Cursor) ?[]const u8 {
        if (self.offset == self.source.len) return null;
        const start = self.offset;
        const end = std.mem.indexOfScalarPos(u8, self.source, start, '\n') orelse self.source.len;
        self.offset = if (end < self.source.len) end + 1 else end;
        return self.source[start..end];
    }

    fn peek(self: Cursor) ?[]const u8 {
        var copy = self;
        return copy.next();
    }
};

pub fn translate(allocator: Allocator, source: []const u8) ![]u8 {
    var output = Writer.Allocating.init(allocator);
    errdefer output.deinit();
    var script = Writer.Allocating.init(allocator);
    defer script.deinit();
    const out = &output.writer;
    try out.writeAll(
        \\local function section(parent,name)
        \\ local value=parent[name]
        \\ if value==nil then value={} parent[name]=value end
        \\ return value
        \\end
        \\local document={}
        \\local current=document
        \\local s1,s2,s3,s4,s5,s6
        \\local function add(value) current[#current+1]=value end
        \\
    );
    var cursor = Cursor{ .source = source };
    var active = [_]bool{false} ** 6;
    var has_lua = false;
    while (cursor.next()) |line| {
        if (trim(line).len == 0) continue;
        if (fenceStart(line)) |language| {
            const is_lua = std.mem.eql(u8, language, "lua");
            has_lua = has_lua or is_lua;
            try emitFence(if (is_lua) &script.writer else out, &cursor, language, is_lua);
        } else if (heading(line)) |item| {
            try emitHeading(out, item.level, item.text, &active);
        } else if (listItem(line) != null) {
            try emitList(out, &cursor, line);
        } else if (!try emitTable(out, &cursor, line)) {
            try emitText(out, &cursor, line);
        }
    }
    if (has_lua) try out.writeAll(script.written()) else try out.writeAll("return document\n");
    return output.toOwnedSlice();
}

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn heading(line: []const u8) ?struct { level: usize, text: []const u8 } {
    const value = trim(line);
    var level: usize = 0;
    while (level < value.len and level < 6 and value[level] == '#') level += 1;
    if (level == 0 or level == value.len or value[level] != ' ') return null;
    const text = trim(value[level + 1 ..]);
    return if (text.len == 0) null else .{ .level = level, .text = text };
}

fn listItem(line: []const u8) ?[]const u8 {
    const value = trim(line);
    if (value.len >= 2 and (value[0] == '-' or value[0] == '*' or value[0] == '+') and value[1] == ' ') return trim(value[2..]);
    var end: usize = 0;
    while (end < value.len and std.ascii.isDigit(value[end])) end += 1;
    if (end == 0 or end + 1 >= value.len or value[end] != '.' or value[end + 1] != ' ') return null;
    return trim(value[end + 2 ..]);
}

fn fenceStart(line: []const u8) ?[]const u8 {
    const value = trim(line);
    return if (std.mem.startsWith(u8, value, "```")) trim(value[3..]) else null;
}

fn emitHeading(out: *Writer, level: usize, text: []const u8, active: *[6]bool) !void {
    const parent = if (std.mem.lastIndexOfScalar(bool, active[0 .. level - 1], true)) |index| index + 1 else 0;
    @memset(active[level - 1 ..], false);
    active[level - 1] = true;
    try out.print("s{d}=section(", .{level});
    if (parent == 0) try out.writeAll("document") else try out.print("s{d}", .{parent});
    try out.writeByte(',');
    try writeLuaString(out, text);
    try out.print(") current=s{d}\n", .{level});
}

fn emitText(out: *Writer, cursor: *Cursor, first_line: []const u8) !void {
    try out.writeAll("add(");
    try writeLuaString(out, first_line);
    while (cursor.peek()) |line| {
        if (blockStart(cursor, line)) break;
        _ = cursor.next();
        try out.writeAll("..\"\\n\"..");
        try writeLuaString(out, line);
    }
    try out.writeAll(")\n");
}

fn emitList(out: *Writer, cursor: *Cursor, first_line: []const u8) !void {
    try out.writeAll("add({");
    try writeLuaString(out, listItem(first_line).?);
    try out.writeByte(',');
    while (cursor.peek()) |line| {
        const item = listItem(line) orelse break;
        _ = cursor.next();
        try writeLuaString(out, item);
        try out.writeByte(',');
    }
    try out.writeAll("})\n");
}

fn emitTable(out: *Writer, cursor: *Cursor, first_line: []const u8) !bool {
    const header = trim(first_line);
    var rest = cursor.*;
    const separator = rest.next() orelse return false;
    const count = tableColumns(header, trim(separator)) orelse return false;
    cursor.* = rest;
    var names = std.mem.splitScalar(u8, header[1 .. header.len - 1], '|');
    var index: usize = 0;
    while (names.next()) |raw| {
        const name = trim(raw);
        if (name.len == 0) return error.InvalidTable;
        var prior = std.mem.splitScalar(u8, header[1 .. header.len - 1], '|');
        for (0..index) |_| if (std.mem.eql(u8, trim(prior.next().?), name)) return error.InvalidTable;
        index += 1;
    }
    try out.writeAll("add({");
    while (cursor.peek()) |line| {
        const row = trim(line);
        if (row.len < 2 or row[0] != '|' or row[row.len - 1] != '|') break;
        _ = cursor.next();
        names = std.mem.splitScalar(u8, header[1 .. header.len - 1], '|');
        var values = std.mem.splitScalar(u8, row[1 .. row.len - 1], '|');
        try out.writeByte('{');
        var columns: usize = 0;
        while (values.next()) |value| {
            const name = names.next() orelse return error.InvalidTable;
            try out.writeByte('[');
            try writeLuaString(out, trim(name));
            try out.writeAll("]=");
            try writeLuaString(out, trim(value));
            try out.writeByte(',');
            columns += 1;
        }
        if (columns != count or names.next() != null) return error.InvalidTable;
        try out.writeAll("},");
    }
    try out.writeAll("})\n");
    return true;
}

fn tableColumns(header: []const u8, separator: []const u8) ?usize {
    if (header.len < 2 or header[0] != '|' or header[header.len - 1] != '|' or
        separator.len < 2 or separator[0] != '|' or separator[separator.len - 1] != '|') return null;
    var cells = std.mem.splitScalar(u8, separator[1 .. separator.len - 1], '|');
    var count: usize = 0;
    while (cells.next()) |raw| {
        const cell = trim(raw);
        if (cell.len < 3) return null;
        for (cell) |byte| if (byte != '-') return null;
        count += 1;
    }
    var headers = std.mem.splitScalar(u8, header[1 .. header.len - 1], '|');
    for (0..count) |_| _ = headers.next() orelse return null;
    return if (headers.next() == null) count else null;
}

fn blockStart(cursor: *Cursor, line: []const u8) bool {
    if (trim(line).len == 0 or heading(line) != null or listItem(line) != null or fenceStart(line) != null) return true;
    var rest = cursor.*;
    const separator = rest.next() orelse return false;
    return tableColumns(trim(line), trim(separator)) != null;
}

fn emitFence(out: *Writer, cursor: *Cursor, language: []const u8, raw: bool) !void {
    if (!raw) {
        try out.writeAll("add({language=");
        try writeLuaString(out, language);
        try out.writeAll(",text=\"\"");
    }
    while (cursor.next()) |line| {
        if (std.mem.eql(u8, trim(line), "```")) {
            if (!raw) try out.writeAll("})\n");
            return;
        }
        if (raw) {
            try out.writeAll(line);
            try out.writeByte('\n');
        } else {
            try out.writeAll("..");
            try writeLuaString(out, line);
            try out.writeAll("..\"\\n\"");
        }
    }
    return error.UnclosedFence;
}

fn writeLuaString(out: *Writer, value: []const u8) !void {
    try out.print("\"{f}\"", .{std.zig.fmtString(value)});
}
