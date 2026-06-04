const std = @import("std");

pub const Token = union(enum) {
    open_tag: []const u8,
    close_tag: []const u8,
    self_closing_tag: []const u8,
    text: []const u8,
    xml_declaration: []const u8,
    comment: []const u8,
};

pub fn tokenize(allocator: std.mem.Allocator, buffer: []const u8) ![]Token {
    var list: std.ArrayList(Token) = .empty;
    try list.ensureTotalCapacity(allocator, buffer.len / 20);

    var i: usize = 0;
    while (i < buffer.len) {
        if (buffer[i] == '<') {
            const start = i;

            if (i + 3 < buffer.len and buffer[i + 1] == '!' and
                buffer[i + 2] == '-' and buffer[i + 3] == '-')
            {
                i += 4;
                while (i + 2 < buffer.len) : (i += 1) {
                    if (buffer[i] == '-' and buffer[i + 1] == '-' and buffer[i + 2] == '>') {
                        i += 3;
                        break;
                    }
                }
                try list.append(allocator, .{ .comment = buffer[start..i] });
                continue;
            }

            if (i + 1 < buffer.len and (buffer[i + 1] == '?' or buffer[i + 1] == '!')) {
                i += 1;
                while (i < buffer.len and buffer[i] != '>') : (i += 1) {}
                if (i < buffer.len) i += 1;
                try list.append(allocator, .{ .xml_declaration = buffer[start..i] });
                continue;
            }

            i += 1;
            while (i < buffer.len and buffer[i] != '>') : (i += 1) {}
            if (i < buffer.len) i += 1;

            const tag_slice = buffer[start..i];

            if (tag_slice.len >= 3 and tag_slice[tag_slice.len - 2] == '/') {
                try list.append(allocator, .{ .self_closing_tag = tag_slice });
            } else if (tag_slice.len >= 3 and tag_slice[1] == '/') {
                try list.append(allocator, .{ .close_tag = tag_slice });
            } else {
                try list.append(allocator, .{ .open_tag = tag_slice });
            }
        } else {
            const start = i;
            while (i < buffer.len and buffer[i] != '<') : (i += 1) {}

            const slice = buffer[start..i];
            if (hasNonWhitespace(slice)) {
                try list.append(allocator, .{ .text = slice });
            }
        }
    }

    return try list.toOwnedSlice(allocator);
}

inline fn hasNonWhitespace(slice: []const u8) bool {
    for (slice) |c| {
        if (c != ' ' and c != '\n' and c != '\r' and c != '\t') {
            return true;
        }
    }
    return false;
}
