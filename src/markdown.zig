const std = @import("std");

const Allocator = std.mem.Allocator;
const List = std.ArrayList(u8);

const Line = struct {
    text: []const u8,
    next: usize,
};

pub fn translate(allocator: Allocator, source: []const u8) ![]u8 {
    var out: List = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
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
        const line = lineAt(source, pos);
        if (trim(line.text).len == 0) {
            pos = line.next;
        } else if (fenceStart(line.text) != null) {
            try emitFence(&out, allocator, source, &pos);
        } else if (heading(line.text) != null) {
            try emitHeading(&out, allocator, line.text, &active);
            pos = line.next;
        } else if (listItem(line.text) != null) {
            try emitList(&out, allocator, source, &pos);
        } else if (tableStart(source, pos)) {
            try emitTable(&out, allocator, source, &pos);
        } else {
            try emitText(&out, allocator, source, &pos);
        }
    }
    try out.appendSlice(allocator, "return root\n");
    return out.toOwnedSlice(allocator);
}

fn lineAt(source: []const u8, pos: usize) Line {
    const end = std.mem.indexOfScalarPos(u8, source, pos, '\n') orelse source.len;
    return .{ .text = source[pos..end], .next = if (end < source.len) end + 1 else end };
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
    if (text.len == 0) return null;
    return .{ .level = level, .text = text };
}

fn listItem(line: []const u8) ?[]const u8 {
    const value = trim(line);
    if (!std.mem.startsWith(u8, value, "- ")) return null;
    return trim(value[2..]);
}

fn tableStart(source: []const u8, pos: usize) bool {
    const header = trim(lineAt(source, pos).text);
    if (header.len < 2 or header[0] != '|' or header[header.len - 1] != '|') return false;
    const first = lineAt(source, pos);
    if (first.next == source.len) return false;
    const separator = trim(lineAt(source, first.next).text);
    if (separator.len < 2 or separator[0] != '|' or separator[separator.len - 1] != '|') return false;
    var rest = separator[1 .. separator.len - 1];
    while (true) {
        const split = std.mem.indexOfScalar(u8, rest, '|');
        const cell = trim(if (split) |at| rest[0..at] else rest);
        if (cell.len < 3) return false;
        for (cell) |byte| if (byte != '-') return false;
        if (split) |at| rest = rest[at + 1 ..] else break;
    }
    return true;
}

fn fenceStart(line: []const u8) ?[]const u8 {
    const value = trim(line);
    if (!std.mem.startsWith(u8, value, "```")) return null;
    return trim(value[3..]);
}

fn emitHeading(out: *List, allocator: Allocator, line: []const u8, active: *[6]bool) !void {
    const item = heading(line).?;
    var parent: usize = 0;
    var index = item.level - 1;
    while (index > 0) {
        index -= 1;
        if (active[index]) {
            parent = index + 1;
            break;
        }
    }
    for (item.level - 1..6) |i| active[i] = false;
    active[item.level - 1] = true;
    try out.append(allocator, 's');
    try out.append(allocator, @intCast('0' + item.level));
    try out.appendSlice(allocator, "=section(");
    if (parent == 0) try out.appendSlice(allocator, "root,") else {
        try out.append(allocator, 's');
        try out.append(allocator, @intCast('0' + parent));
        try out.append(allocator, ',');
    }
    try writeLuaString(out, allocator, item.text);
    try out.appendSlice(allocator, ") current=s");
    try out.append(allocator, @intCast('0' + item.level));
    try out.append(allocator, '\n');
}

fn emitText(out: *List, allocator: Allocator, source: []const u8, pos: *usize) !void {
    try out.appendSlice(allocator, "add(");
    var first = true;
    while (pos.* < source.len) {
        const line = lineAt(source, pos.*);
        if (trim(line.text).len == 0 or heading(line.text) != null or listItem(line.text) != null or fenceStart(line.text) != null or tableStart(source, pos.*)) break;
        if (!first) try out.appendSlice(allocator, "..\"\\n\"..");
        try writeLuaString(out, allocator, line.text);
        first = false;
        pos.* = line.next;
    }
    try out.appendSlice(allocator, ")\n");
}

fn emitList(out: *List, allocator: Allocator, source: []const u8, pos: *usize) !void {
    try out.appendSlice(allocator, "add({");
    while (pos.* < source.len) {
        const line = lineAt(source, pos.*);
        const item = listItem(line.text) orelse break;
        try writeLuaString(out, allocator, item);
        try out.append(allocator, ',');
        pos.* = line.next;
    }
    try out.appendSlice(allocator, "})\n");
}

fn emitTable(out: *List, allocator: Allocator, source: []const u8, pos: *usize) !void {
    const header_line = lineAt(source, pos.*);
    const header = trim(header_line.text);
    var headers = header[1 .. header.len - 1];
    var count: usize = 0;
    while (true) {
        const split = std.mem.indexOfScalar(u8, headers, '|');
        const cell = trim(if (split) |at| headers[0..at] else headers);
        if (cell.len == 0) return error.InvalidTable;
        var prior = header[1 .. header.len - 1];
        var seen: usize = 0;
        while (seen < count) : (seen += 1) {
            const at = std.mem.indexOfScalar(u8, prior, '|');
            const old = trim(if (at) |i| prior[0..i] else prior);
            if (std.mem.eql(u8, old, cell)) return error.InvalidTable;
            prior = if (at) |i| prior[i + 1 ..] else "";
        }
        count += 1;
        if (split) |at| headers = headers[at + 1 ..] else break;
    }
    const separator_line = lineAt(source, header_line.next);
    const separator = trim(separator_line.text);
    var separators = separator[1 .. separator.len - 1];
    var separator_count: usize = 0;
    while (true) {
        separator_count += 1;
        const split = std.mem.indexOfScalar(u8, separators, '|');
        if (split) |at| separators = separators[at + 1 ..] else break;
    }
    if (separator_count != count) return error.InvalidTable;
    pos.* = separator_line.next;
    try out.appendSlice(allocator, "add({");
    while (pos.* < source.len) {
        const line = lineAt(source, pos.*);
        const row = trim(line.text);
        if (row.len < 2 or row[0] != '|' or row[row.len - 1] != '|') break;
        var values = row[1 .. row.len - 1];
        var names = header[1 .. header.len - 1];
        var column: usize = 0;
        try out.append(allocator, '{');
        while (true) {
            const value_at = std.mem.indexOfScalar(u8, values, '|');
            const name_at = std.mem.indexOfScalar(u8, names, '|');
            if (column == count) return error.InvalidTable;
            try out.append(allocator, '[');
            try writeLuaString(out, allocator, trim(if (name_at) |at| names[0..at] else names));
            try out.appendSlice(allocator, "]=");
            try writeLuaString(out, allocator, trim(if (value_at) |at| values[0..at] else values));
            try out.append(allocator, ',');
            column += 1;
            if (value_at) |at| values = values[at + 1 ..] else break;
            names = if (name_at) |at| names[at + 1 ..] else return error.InvalidTable;
        }
        if (column != count) return error.InvalidTable;
        try out.appendSlice(allocator, "},");
        pos.* = line.next;
    }
    try out.appendSlice(allocator, "})\n");
}

fn emitFence(out: *List, allocator: Allocator, source: []const u8, pos: *usize) !void {
    const opening = lineAt(source, pos.*);
    try out.appendSlice(allocator, "add({language=");
    try writeLuaString(out, allocator, fenceStart(opening.text).?);
    try out.appendSlice(allocator, ",text=\"\"");
    pos.* = opening.next;
    while (pos.* < source.len) {
        const line = lineAt(source, pos.*);
        if (std.mem.eql(u8, trim(line.text), "```")) {
            pos.* = line.next;
            try out.appendSlice(allocator, "})\n");
            return;
        }
        try out.appendSlice(allocator, "..");
        try writeLuaString(out, allocator, line.text);
        try out.appendSlice(allocator, "..\"\\n\"");
        pos.* = line.next;
    }
    return error.UnclosedFence;
}

fn writeLuaString(out: *List, allocator: Allocator, value: []const u8) !void {
    const hex = "0123456789abcdef";
    try out.append(allocator, '"');
    for (value) |byte| switch (byte) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        0...8, 11...12, 14...31, 127...255 => try out.appendSlice(allocator, &.{ '\\', 'x', hex[byte >> 4], hex[byte & 15] }),
        else => try out.append(allocator, byte),
    };
    try out.append(allocator, '"');
}
