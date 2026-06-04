const std = @import("std");
const parser = @import("../html/xhtml_parser.zig");
const block_mod = @import("block.zig");

const Block = block_mod.Block;
const TextStyle = block_mod.TextStyle;

pub const BlockExtractCtx = struct {
    allocator: std.mem.Allocator,
    blocks: *std.ArrayList(Block),
    current_text: std.ArrayList(u8),
    style_stack: std.ArrayList(TextStyle),
    container_depth: usize,

    pub fn currentStyle(self: *BlockExtractCtx) TextStyle {
        if (self.style_stack.items.len == 0) return .body;
        return self.style_stack.items[self.style_stack.items.len - 1];
    }

    pub fn flushText(self: *BlockExtractCtx) !void {
        const trimmed = std.mem.trim(u8, self.current_text.items, " \n\r\t");
        if (trimmed.len == 0) {
            self.current_text.clearRetainingCapacity();
            return;
        }
        const cleaned = try collapseWhitespace(self.allocator, trimmed);
        if (cleaned.len == 0) {
            self.allocator.free(cleaned);
            self.current_text.clearRetainingCapacity();
            return;
        }
        try self.blocks.append(self.allocator, .{
            .kind = .{ .text = self.currentStyle() },
            .content = cleaned,
        });
        self.current_text.clearRetainingCapacity();
    }

    pub fn appendText(self: *BlockExtractCtx, text: []const u8) !void {
        try self.current_text.appendSlice(self.allocator, text);
    }

    pub fn paragraphBreak(self: *BlockExtractCtx) !void {
        if (self.current_text.items.len == 0) return;
        var trailing_newlines: usize = 0;
        var i = self.current_text.items.len;
        var has_content = false;
        while (i > 0) : (i -= 1) {
            const c = self.current_text.items[i - 1];
            if (c == '\n') {
                trailing_newlines += 1;
            } else if (c == ' ' or c == '\t') {
                continue;
            } else {
                has_content = true;
                break;
            }
        }
        if (!has_content) return;
        if (trailing_newlines >= 2) return;
        if (trailing_newlines == 1) {
            try self.appendText("\n");
        } else {
            try self.appendText("\n\n");
        }
    }

    pub fn walk(self: *BlockExtractCtx, node: *parser.Node) !void {
        if (node.text_content) |text| {
            const decoded = try decodeEntities(self.allocator, text);
            defer self.allocator.free(decoded);
            try self.appendText(decoded);
            return;
        }

        const tag = node.tag_name orelse {
            for (node.children.items) |child| {
                try self.walk(child);
            }
            return;
        };

        if (eq(tag, "head") or eq(tag, "title") or eq(tag, "script") or eq(tag, "style") or eq(tag, "meta") or eq(tag, "link")) {
            return;
        }

        if (eq(tag, "br")) {
            try self.appendText("\n");
            return;
        }

        const is_container = eq(tag, "blockquote") or eq(tag, "pre") or eq(tag, "li");

        if (self.container_depth > 0 and !is_container) {
            const child_block = isBlockTag(tag);
            if (child_block) try self.paragraphBreak();
            for (node.children.items) |child| {
                try self.walk(child);
            }
            if (child_block) try self.paragraphBreak();
            return;
        }

        if (eq(tag, "img") or eq(tag, "image")) {
            try self.flushText();
            const src = findImageSrc(node);
            if (src) |s| {
                if (s.len > 0) {
                    const copy = try self.allocator.dupe(u8, s);
                    try self.blocks.append(self.allocator, .{
                        .kind = .image,
                        .content = copy,
                    });
                }
            }
            return;
        }

        if (eq(tag, "hr")) {
            try self.flushText();
            const empty = try self.allocator.dupe(u8, "");
            try self.blocks.append(self.allocator, .{
                .kind = .separator,
                .content = empty,
            });
            return;
        }

        const style_override: ?TextStyle = if (eq(tag, "h1"))
            .heading_1
        else if (eq(tag, "h2"))
            .heading_2
        else if (eq(tag, "h3"))
            .heading_3
        else if (eq(tag, "h4") or eq(tag, "h5") or eq(tag, "h6"))
            .heading_4
        else if (eq(tag, "blockquote"))
            .blockquote
        else if (eq(tag, "li"))
            .list_item
        else if (eq(tag, "pre"))
            .code
        else if (eq(tag, "figcaption") or eq(tag, "caption"))
            .caption
        else
            null;

        const block_tag = isBlockTag(tag);

        if (block_tag) {
            try self.flushText();
        }

        if (style_override) |_| {
            try self.flushText();
        }

        if (style_override) |s| {
            try self.style_stack.append(self.allocator, s);
        }

        if (is_container) self.container_depth += 1;

        for (node.children.items) |child| {
            try self.walk(child);
        }

        if (is_container) self.container_depth -= 1;

        if (style_override != null) {
            try self.flushText();
            _ = self.style_stack.pop();
        } else if (block_tag) {
            try self.flushText();
        }
    }
};

pub fn isBlockTag(tag: []const u8) bool {
    return eq(tag, "p") or
        eq(tag, "div") or
        eq(tag, "section") or
        eq(tag, "article") or
        eq(tag, "header") or
        eq(tag, "footer") or
        eq(tag, "main") or
        eq(tag, "figure") or
        eq(tag, "figcaption") or
        eq(tag, "h1") or eq(tag, "h2") or eq(tag, "h3") or
        eq(tag, "h4") or eq(tag, "h5") or eq(tag, "h6") or
        eq(tag, "blockquote") or
        eq(tag, "li") or
        eq(tag, "ul") or eq(tag, "ol") or
        eq(tag, "pre");
}

pub fn eq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = std.ascii.toLower(ca);
        const lb = std.ascii.toLower(cb);
        if (la != lb) return false;
    }
    return true;
}

pub fn findImageSrc(node: *parser.Node) ?[]const u8 {
    var iter = node.attributes.iterator();
    while (iter.next()) |entry| {
        if (eq(entry.key_ptr.*, "src") or eq(entry.key_ptr.*, "xlink:href") or eq(entry.key_ptr.*, "href")) {
            return entry.value_ptr.*;
        }
    }
    return null;
}

pub fn collapseWhitespace(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var prev_space = false;
    var line_start = true;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == '\r') continue;
        if (c == '\n') {
            while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
                _ = out.pop();
            }
            try out.append(allocator, '\n');
            prev_space = false;
            line_start = true;
            continue;
        }
        if (c == ' ' or c == '\t') {
            if (line_start) continue;
            if (prev_space) continue;
            try out.append(allocator, ' ');
            prev_space = true;
            continue;
        }
        try out.append(allocator, c);
        prev_space = false;
        line_start = false;
    }

    while (out.items.len > 0 and (out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == '\n')) {
        _ = out.pop();
    }

    return out.toOwnedSlice(allocator);
}

pub fn decodeEntities(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '&') {
            if (std.mem.indexOfScalarPos(u8, input, i, ';')) |end| {
                if (end - i <= 10) {
                    const entity = input[i .. end + 1];
                    if (std.mem.eql(u8, entity, "&amp;")) {
                        try out.append(allocator, '&');
                        i = end + 1;
                        continue;
                    } else if (std.mem.eql(u8, entity, "&lt;")) {
                        try out.append(allocator, '<');
                        i = end + 1;
                        continue;
                    } else if (std.mem.eql(u8, entity, "&gt;")) {
                        try out.append(allocator, '>');
                        i = end + 1;
                        continue;
                    } else if (std.mem.eql(u8, entity, "&quot;")) {
                        try out.append(allocator, '"');
                        i = end + 1;
                        continue;
                    } else if (std.mem.eql(u8, entity, "&apos;")) {
                        try out.append(allocator, '\'');
                        i = end + 1;
                        continue;
                    } else if (std.mem.eql(u8, entity, "&nbsp;")) {
                        try out.append(allocator, ' ');
                        i = end + 1;
                        continue;
                    } else if (std.mem.eql(u8, entity, "&mdash;")) {
                        try out.appendSlice(allocator, "\u{2014}");
                        i = end + 1;
                        continue;
                    } else if (std.mem.eql(u8, entity, "&ndash;")) {
                        try out.appendSlice(allocator, "\u{2013}");
                        i = end + 1;
                        continue;
                    } else if (std.mem.eql(u8, entity, "&hellip;")) {
                        try out.appendSlice(allocator, "\u{2026}");
                        i = end + 1;
                        continue;
                    } else if (std.mem.eql(u8, entity, "&lsquo;")) {
                        try out.appendSlice(allocator, "\u{2018}");
                        i = end + 1;
                        continue;
                    } else if (std.mem.eql(u8, entity, "&rsquo;")) {
                        try out.appendSlice(allocator, "\u{2019}");
                        i = end + 1;
                        continue;
                    } else if (std.mem.eql(u8, entity, "&ldquo;")) {
                        try out.appendSlice(allocator, "\u{201C}");
                        i = end + 1;
                        continue;
                    } else if (std.mem.eql(u8, entity, "&rdquo;")) {
                        try out.appendSlice(allocator, "\u{201D}");
                        i = end + 1;
                        continue;
                    } else if (entity.len > 3 and entity[1] == '#') {
                        const num_str = entity[2 .. entity.len - 1];
                        const code: ?u21 = if (num_str.len > 1 and (num_str[0] == 'x' or num_str[0] == 'X'))
                            std.fmt.parseInt(u21, num_str[1..], 16) catch null
                        else
                            std.fmt.parseInt(u21, num_str, 10) catch null;
                        if (code) |cp| {
                            var buf: [4]u8 = undefined;
                            const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                            if (n > 0) {
                                try out.appendSlice(allocator, buf[0..n]);
                                i = end + 1;
                                continue;
                            }
                        }
                    }
                }
            }
        }
        try out.append(allocator, input[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}
