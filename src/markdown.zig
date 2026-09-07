const std = @import("std");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub fn translate(allocator: Allocator, source: []const u8) ![]u8 {
    var output = Writer.Allocating.init(allocator);
    errdefer output.deinit();
    const out = &output.writer;
    try out.writeAll(
        \\local function section(parent,name)
        \\ local value=parent[name]
        \\ if value==nil then value={} parent[name]=value end
        \\ return value
        \\end
        \\local root={}
        \\local current=root
        \\local s1,s2,s3,s4,s5,s6
        \\local function add(value) current[#current+1]=value end
        \\
    );
    var active = [_]bool{false} ** 6;
    var pos: usize = 0;
    while (pos < source.len) {
        var next = pos;
        const line = lineAt(source, &next);
        if (trim(line).len == 0) {
            pos = next;
        } else if (fenceStart(line) != null) {
            try emitFence(out, source, &pos);
        } else if (heading(line)) |item| {
            try emitHeading(out, item.level, item.text, &active);
            pos = next;
        } else if (listItem(line) != null) {
            try emitList(out, source, &pos);
        } else if (tableStart(source, pos)) {
            try emitTable(out, source, &pos);
        } else {
            try emitText(out, source, &pos);
        }
    }
    try out.writeAll("return root\n");
    return output.toOwnedSlice();
}

fn lineAt(source: []const u8, pos: *usize) []const u8 {
    const start = pos.*;
    const end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
    pos.* = if (end < source.len) end + 1 else end;
    return source[start..end];
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
    return if (std.mem.startsWith(u8, value, "- ")) trim(value[2..]) else null;
}

fn tableStart(source: []const u8, pos: usize) bool {
    var next = pos;
    const header = trim(lineAt(source, &next));
    if (header.len < 2 or header[0] != '|' or header[header.len - 1] != '|' or next == source.len) return false;
    const separator = trim(lineAt(source, &next));
    if (separator.len < 2 or separator[0] != '|' or separator[separator.len - 1] != '|') return false;
    var cells = std.mem.splitScalar(u8, separator[1 .. separator.len - 1], '|');
    while (cells.next()) |raw| {
        const cell = trim(raw);
        if (cell.len < 3) return false;
        for (cell) |byte| if (byte != '-') return false;
    }
    return true;
}

fn fenceStart(line: []const u8) ?[]const u8 {
    const value = trim(line);
    return if (std.mem.startsWith(u8, value, "```")) trim(value[3..]) else null;
}

fn emitHeading(out: *Writer, level: usize, text: []const u8, active: *[6]bool) !void {
    var parent: usize = 0;
    var index = level - 1;
    while (index > 0) {
        index -= 1;
        if (active[index]) {
            parent = index + 1;
            break;
        }
    }
    for (level - 1..6) |i| active[i] = false;
    active[level - 1] = true;
    try out.print("s{d}=section(", .{level});
    if (parent == 0) try out.writeAll("root") else try out.print("s{d}", .{parent});
    try out.writeByte(',');
    try writeLuaString(out, text);
    try out.print(") current=s{d}\n", .{level});
}

fn emitText(out: *Writer, source: []const u8, pos: *usize) !void {
    try out.writeAll("add(");
    var first = true;
    while (pos.* < source.len) {
        var next = pos.*;
        const line = lineAt(source, &next);
        if (trim(line).len == 0 or heading(line) != null or listItem(line) != null or fenceStart(line) != null or tableStart(source, pos.*)) break;
        if (!first) try out.writeAll("..\"\\n\"..");
        try writeLuaString(out, line);
        first = false;
        pos.* = next;
    }
    try out.writeAll(")\n");
}

fn emitList(out: *Writer, source: []const u8, pos: *usize) !void {
    try out.writeAll("add({");
    while (pos.* < source.len) {
        var next = pos.*;
        const item = listItem(lineAt(source, &next)) orelse break;
        try writeLuaString(out, item);
        try out.writeByte(',');
        pos.* = next;
    }
    try out.writeAll("})\n");
}

fn emitTable(out: *Writer, source: []const u8, pos: *usize) !void {
    const header = trim(lineAt(source, pos));
    var headers = std.mem.splitScalar(u8, header[1 .. header.len - 1], '|');
    var count: usize = 0;
    while (headers.next()) |raw| {
        const name = trim(raw);
        if (name.len == 0) return error.InvalidTable;
        var prior = std.mem.splitScalar(u8, header[1 .. header.len - 1], '|');
        for (0..count) |_| if (std.mem.eql(u8, trim(prior.next().?), name)) return error.InvalidTable;
        count += 1;
    }
    const separator = trim(lineAt(source, pos));
    var separators = std.mem.splitScalar(u8, separator[1 .. separator.len - 1], '|');
    var separator_count: usize = 0;
    while (separators.next() != null) separator_count += 1;
    if (separator_count != count) return error.InvalidTable;
    try out.writeAll("add({");
    while (pos.* < source.len) {
        var next = pos.*;
        const row = trim(lineAt(source, &next));
        if (row.len < 2 or row[0] != '|' or row[row.len - 1] != '|') break;
        var names = std.mem.splitScalar(u8, header[1 .. header.len - 1], '|');
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
        pos.* = next;
    }
    try out.writeAll("})\n");
}

fn emitFence(out: *Writer, source: []const u8, pos: *usize) !void {
    try out.writeAll("add({language=");
    try writeLuaString(out, fenceStart(lineAt(source, pos)).?);
    try out.writeAll(",text=\"\"");
    while (pos.* < source.len) {
        const line = lineAt(source, pos);
        if (std.mem.eql(u8, trim(line), "```")) {
            try out.writeAll("})\n");
            return;
        }
        try out.writeAll("..");
        try writeLuaString(out, line);
        try out.writeAll("..\"\\n\"");
    }
    return error.UnclosedFence;
}

fn writeLuaString(out: *Writer, value: []const u8) !void {
    const hex = "0123456789abcdef";
    try out.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try out.writeAll("\\\""),
        '\\' => try out.writeAll("\\\\"),
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        '\t' => try out.writeAll("\\t"),
        0...8, 11...12, 14...31, 127...255 => try out.writeAll(&.{ '\\', 'x', hex[byte >> 4], hex[byte & 15] }),
        else => try out.writeByte(byte),
    };
    try out.writeByte('"');
}
