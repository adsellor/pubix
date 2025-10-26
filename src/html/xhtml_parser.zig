const std = @import("std");
const Token = @import("./xhtml_tokenizer.zig").Token;

pub const Node = struct {
    tag_name: ?[]const u8 = null,
    text_content: ?[]const u8 = null,
    children: std.ArrayList(*Node),
    parent: ?*Node = null,
    attributes: std.StringArrayHashMapUnmanaged([]const u8),

    pub fn create(allocator: std.mem.Allocator) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .children = .{},
            .attributes = .{},
        };
        return node;
    }

    pub fn destroy(self: *Node, allocator: std.mem.Allocator) void {
        for (self.children.items) |child| {
            child.destroy(allocator);
        }
        self.children.deinit(allocator);
        self.attributes.deinit(allocator);
        allocator.destroy(self);
    }
};

pub fn parse(allocator: std.mem.Allocator, tokens: []Token) !*Node {
    const root = try Node.create(allocator);
    errdefer root.destroy(allocator);

    var stack: std.ArrayList(*Node) = .{};
    defer stack.deinit(allocator);

    try stack.ensureTotalCapacity(allocator, 32);
    try stack.append(allocator, root);

    for (tokens) |token| {
        if (stack.items.len == 0) {
            return error.MalformedXHTML;
        }

        const current = stack.items[stack.items.len - 1];

        switch (token) {
            .open_tag => |tag| {
                const element = try Node.create(allocator);
                errdefer element.destroy(allocator);

                element.parent = current;
                try parseTagAndAttributes(allocator, tag, element);

                try current.children.append(allocator, element);
                try stack.append(allocator, element);
            },

            .close_tag => |tag| {
                if (stack.items.len <= 1) {
                    return error.UnexpectedClosingTag;
                }

                const top = stack.items[stack.items.len - 1];
                if (top.tag_name) |name| {
                    const tag_name = extractTagNameInline(tag);
                    if (!std.mem.eql(u8, name, tag_name)) {
                        std.debug.print("Expected </{s}> but got </{s}>\n", .{ name, tag_name });
                        return error.MismatchedTags;
                    }
                }
                _ = stack.pop();
            },

            .self_closing_tag => |tag| {
                const element = try Node.create(allocator);
                errdefer element.destroy(allocator);

                element.parent = current;
                try parseTagAndAttributes(allocator, tag, element);
                try current.children.append(allocator, element);
            },

            .text => |content| {
                const text_node = try Node.create(allocator);
                errdefer text_node.destroy(allocator);

                text_node.text_content = content;
                text_node.parent = current;
                try current.children.append(allocator, text_node);
            },

            .xml_declaration, .comment => {},
        }
    }

    if (stack.items.len != 1) {
        return error.UnclosedTags;
    }

    return root;
}

inline fn extractTagNameInline(tag: []const u8) []const u8 {
    var start: usize = 1;
    if (tag.len > 1 and tag[1] == '/') start = 2;

    var end = start;
    while (end < tag.len) : (end += 1) {
        const c = tag[end];
        if (c == '>' or c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '/') {
            break;
        }
    }

    return tag[start..end];
}

pub fn extractTagName(allocator: std.mem.Allocator, tag: []const u8) ![]const u8 {
    return try allocator.dupe(u8, extractTagNameInline(tag));
}

pub fn parseTagAndAttributes(allocator: std.mem.Allocator, tag: []const u8, node: *Node) !void {
    var i: usize = 1;
    const start = i;

    while (i < tag.len) : (i += 1) {
        const c = tag[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '>' or c == '/') {
            break;
        }
    }

    node.tag_name = tag[start..i];

    while (i < tag.len and isWhitespace(tag[i])) : (i += 1) {}

    while (i < tag.len and tag[i] != '>' and tag[i] != '/') {
        const attr_start = i;

        while (i < tag.len and tag[i] != '=' and !isWhitespace(tag[i]) and tag[i] != '>' and tag[i] != '/') : (i += 1) {}

        const attr_name = tag[attr_start..i];

        while (i < tag.len and (isWhitespace(tag[i]) or tag[i] == '=')) : (i += 1) {}

        if (i >= tag.len or tag[i] == '>' or tag[i] == '/') {
            if (attr_name.len > 0) {
                try node.attributes.put(allocator, attr_name, "");
            }
            break;
        }

        const quote_char = tag[i];
        if (quote_char != '"' and quote_char != '\'') {
            const value_start = i;
            while (i < tag.len and !isWhitespace(tag[i]) and tag[i] != '>' and tag[i] != '/') : (i += 1) {}
            const attr_value = tag[value_start..i];
            try node.attributes.put(allocator, attr_name, attr_value);
        } else {
            i += 1;
            const value_start = i;

            while (i < tag.len and tag[i] != quote_char) : (i += 1) {}

            const attr_value = tag[value_start..i];
            if (i < tag.len) i += 1;

            try node.attributes.put(allocator, attr_name, attr_value);
        }

        while (i < tag.len and isWhitespace(tag[i])) : (i += 1) {}
    }
}

inline fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}
