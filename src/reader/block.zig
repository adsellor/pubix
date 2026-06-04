const std = @import("std");
const dvui = @import("dvui");
const theme_mod = @import("theme.zig");

const Color = dvui.Color;
const mocha = theme_mod.mocha;

pub const TextStyle = enum {
    body,
    heading_1,
    heading_2,
    heading_3,
    heading_4,
    blockquote,
    list_item,
    code,
    caption,
};

pub const BlockKind = union(enum) {
    text: TextStyle,
    image,
    separator,
};

pub const Block = struct {
    kind: BlockKind,
    content: []const u8,

    pub fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

pub const PageRange = struct {
    start: usize,
    end: usize,
};

pub fn isHeadingBlock(block: Block) bool {
    return switch (block.kind) {
        .text => |s| s == .heading_1 or s == .heading_2 or s == .heading_3 or s == .heading_4,
        else => false,
    };
}

pub fn fontForStyle(style: TextStyle) dvui.Font {
    const t = dvui.themeGet();
    return switch (style) {
        .body, .list_item => t.font_body,
        .heading_1 => t.font_title.withSize(t.font_title.size + 4),
        .heading_2 => t.font_title,
        .heading_3 => t.font_heading.withSize(t.font_heading.size + 4),
        .heading_4 => t.font_heading.withSize(t.font_heading.size + 2),
        .blockquote => t.font_body.withStyle(.italic).withLineHeight(1.55),
        .code => t.font_mono,
        .caption => t.font_body.withSize(t.font_body.size - 3).withStyle(.italic).withLineHeight(1.3),
    };
}

pub fn paddingForStyle(style: TextStyle) dvui.Rect {
    return switch (style) {
        .body => .{ .x = 0, .y = 4, .w = 0, .h = 6 },
        .heading_1 => .{ .x = 0, .y = 22, .w = 0, .h = 14 },
        .heading_2 => .{ .x = 0, .y = 18, .w = 0, .h = 10 },
        .heading_3 => .{ .x = 0, .y = 14, .w = 0, .h = 8 },
        .heading_4 => .{ .x = 0, .y = 12, .w = 0, .h = 6 },
        .blockquote => .{ .x = 36, .y = 26, .w = 48, .h = 26 },
        .list_item => .{ .x = 22, .y = 2, .w = 4, .h = 4 },
        .code => .{ .x = 24, .y = 22, .w = 24, .h = 22 },
        .caption => .{ .x = 0, .y = 4, .w = 0, .h = 4 },
    };
}

pub fn colorForStyle(style: TextStyle) Color {
    return switch (style) {
        .body, .list_item => mocha.base00,
        .heading_1, .heading_2 => mocha.base0A,
        .heading_3, .heading_4 => mocha.base02,
        .blockquote => mocha.base02,
        .code => mocha.base0A,
        .caption => mocha.base04,
    };
}
