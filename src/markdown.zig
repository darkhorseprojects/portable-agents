const std = @import("std");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Lines = @TypeOf(std.mem.splitScalar(u8, "", '\n'));

fn peek(lines: Lines) ?[]const u8 {
    var copy = lines;
    return copy.next();
}

pub fn translate(allocator: Allocator, source: []const u8) ![]u8 {
    var output = Writer.Allocating.init(allocator);
    errdefer output.deinit();
    var script = Writer.Allocating.init(allocator);
    defer script.deinit();
    const out = &output.writer;
    try out.writeAll(
        \\local require=require("pa")._bindDocument(function(root)
        \\ local function section(parent,name)
        \\  local value=parent[name]
        \\  if value==nil then value={} parent[name]=value end
        \\  return value
        \\ end
        \\ local current=root
        \\ local s1,s2,s3,s4,s5,s6
        \\ local function add(value) current[#current+1]=value end
        \\
    );
    var lines = std.mem.splitScalar(u8, source, '\n');
    var active = [_]bool{false} ** 6;
    var has_lua = false;
    while (lines.next()) |line| {
        if (trim(line).len == 0) continue;
        if (fenceStart(line)) |language| {
            const is_lua = std.mem.eql(u8, language, "lua");
            has_lua = has_lua or is_lua;
            try emitFence(if (is_lua) &script.writer else out, &lines, language, is_lua);
        } else if (heading(line)) |item| {
            try emitHeading(out, item.level, item.text, &active);
        } else if (listItem(line) != null) {
            try emitList(out, &lines, line);
        } else if (!try emitTable(out, &lines, line)) {
            try emitText(out, &lines, line);
        }
    }
    try out.writeAll("end)\n");
    if (has_lua) try out.writeAll(script.written()) else try out.writeAll("return require(\"pa\").document()\n");
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
    if (parent == 0) try out.writeAll("root") else try out.print("s{d}", .{parent});
    try out.writeByte(',');
    try writeLuaString(out, text);
    try out.print(") current=s{d}\n", .{level});
}

fn emitText(out: *Writer, lines: *Lines, first_line: []const u8) !void {
    try out.writeAll("add(");
    try writeLuaString(out, first_line);
    while (peek(lines.*)) |line| {
        if (blockStart(lines, line)) break;
        _ = lines.next();
        try out.writeAll("..\"\\n\"..");
        try writeLuaString(out, line);
    }
    try out.writeAll(")\n");
}

fn emitList(out: *Writer, lines: *Lines, first_line: []const u8) !void {
    try out.writeAll("add({");
    try writeLuaString(out, listItem(first_line).?);
    try out.writeByte(',');
    while (peek(lines.*)) |line| {
        const item = listItem(line) orelse break;
        _ = lines.next();
        try writeLuaString(out, item);
        try out.writeByte(',');
    }
    try out.writeAll("})\n");
}

fn emitTable(out: *Writer, lines: *Lines, first_line: []const u8) !bool {
    var rest = lines.*;
    const separator = rest.next() orelse return false;
    const count = tableColumns(first_line, separator) orelse return false;
    lines.* = rest;
    try out.writeAll("add({");
    while (peek(lines.*)) |line| {
        var values = tableCells(line) orelse break;
        _ = lines.next();
        var names = tableCells(first_line).?;
        try out.writeByte('{');
        var columns: usize = 0;
        while (values.next()) |value| {
            const name = names.next() orelse return error.InvalidTable;
            if (trim(name).len == 0) return error.InvalidTable;
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

fn tableCells(line: []const u8) ?Lines {
    const value = trim(line);
    if (value.len < 2 or value[0] != '|' or value[value.len - 1] != '|') return null;
    return std.mem.splitScalar(u8, value[1 .. value.len - 1], '|');
}

fn tableColumns(header: []const u8, separator: []const u8) ?usize {
    var cells = tableCells(separator) orelse return null;
    var count: usize = 0;
    while (cells.next()) |raw| {
        const cell = trim(raw);
        if (cell.len < 3) return null;
        for (cell) |byte| if (byte != '-') return null;
        count += 1;
    }
    var headers = tableCells(header) orelse return null;
    for (0..count) |_| _ = headers.next() orelse return null;
    return if (headers.next() == null) count else null;
}

fn blockStart(lines: *Lines, line: []const u8) bool {
    if (trim(line).len == 0 or heading(line) != null or listItem(line) != null or fenceStart(line) != null) return true;
    var rest = lines.*;
    _ = rest.next();
    const separator = rest.next() orelse return false;
    return tableColumns(line, separator) != null;
}

fn emitFence(out: *Writer, lines: *Lines, language: []const u8, raw: bool) !void {
    if (!raw) {
        try out.writeAll("add({language=");
        try writeLuaString(out, language);
        try out.writeAll(",text=\"\"");
    }
    while (lines.next()) |line| {
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
