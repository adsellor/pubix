const std = @import("std");
const dvui = @import("dvui");

const theme_mod = @import("theme.zig");
const block_mod = @import("block.zig");
const layout_mod = @import("layout.zig");
const state_mod = @import("state.zig");

const mocha = theme_mod.mocha;
const TextStyle = block_mod.TextStyle;
const Block = block_mod.Block;
const fontForStyle = block_mod.fontForStyle;
const paddingForStyle = block_mod.paddingForStyle;
const colorForStyle = block_mod.colorForStyle;
const column_gutter = layout_mod.column_gutter;
const page_outer_margin = layout_mod.page_outer_margin;
const image_max_height = layout_mod.image_max_height;
const image_vertical_margin = layout_mod.image_vertical_margin;
const computeImageDisplaySize = layout_mod.computeImageDisplaySize;
const ReaderState = state_mod.ReaderState;

pub fn renderTopBar(state: *ReaderState) void {
    var top_bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = 44 },
        .background = true,
        .color_fill = mocha.base0F,
        .padding = dvui.Rect.all(12),
        .border = dvui.Rect{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .color_border = mocha.base05,
    });
    defer top_bar.deinit();

    if (state.chapters) |chapters| {
        if (state.current_chapter < chapters.items.len) {
            const chapter = chapters.items[state.current_chapter];

            var title_buf: [256]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buf, "Chapter {d}/{d}: {s}", .{
                state.current_chapter + 1,
                chapters.items.len,
                chapter.title,
            }) catch "Chapter";

            dvui.label(@src(), "{s}", .{title}, .{
                .font = dvui.themeGet().font_heading,
                .color_text = mocha.base00,
                .gravity_y = 0.5,
                .expand = .horizontal,
            });

            var page_buf: [64]u8 = undefined;
            const total = @max(state.chapter_pages.pages.items.len, 1);
            const left = state.chapter_pages.current_page + 1;
            const page_text = switch (state.chapter_pages.layout) {
                .single => std.fmt.bufPrint(&page_buf, "Page {d}/{d}", .{ left, total }) catch "",
                .double => blk: {
                    const right = @min(left + 1, total);
                    break :blk std.fmt.bufPrint(&page_buf, "Pages {d}–{d}/{d}", .{ left, right, total }) catch "";
                },
            };

            dvui.label(@src(), "{s}", .{page_text}, .{
                .font = fontForStyle(.caption),
                .color_text = mocha.base03,
                .gravity_y = 0.5,
                .gravity_x = 1.0,
            });
        }
    } else {
        dvui.label(@src(), "PubiX Reader", .{}, .{
            .font = dvui.themeGet().font_heading,
            .color_text = mocha.base00,
            .gravity_y = 0.5,
        });
    }
}

pub fn renderContent(state: *ReaderState) void {
    var outer = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .background = true,
        .color_fill = mocha.base07,
        .padding = .{ .x = page_outer_margin, .y = 20, .w = page_outer_margin, .h = 20 },
    });
    defer outer.deinit();

    if (state.chapter_pages.pages.items.len == 0) return;
    if (state.chapter_pages.current_page >= state.chapter_pages.pages.items.len) return;

    const layout = state.chapter_pages.layout;
    const column_width = state.chapter_pages.paginated_column_width;

    _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = 0 });

    switch (layout) {
        .single => {
            renderPageColumn(state, state.chapter_pages.current_page, column_width, 0);
        },
        .double => {
            renderPageColumn(state, state.chapter_pages.current_page, column_width, 0);
            _ = dvui.spacer(@src(), .{
                .id_extra = 1,
                .min_size_content = .{ .w = column_gutter, .h = 0 },
            });
            if (state.chapter_pages.current_page + 1 < state.chapter_pages.pages.items.len) {
                renderPageColumn(state, state.chapter_pages.current_page + 1, column_width, 1);
            } else {
                renderEmptyColumn(column_width);
            }
        },
    }

    _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = 2 });
}

fn renderPageColumn(state: *ReaderState, page_index: usize, column_width: f32, id_extra: usize) void {
    var column = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id_extra,
        .min_size_content = .{ .w = column_width },
        .max_size_content = .{ .w = column_width, .h = std.math.floatMax(f32) },
        .expand = .vertical,
        .background = false,
    });
    defer column.deinit();

    const page = state.chapter_pages.pages.items[page_index];
    const blocks = state.chapter_pages.blocks[page.start..page.end];

    for (blocks, 0..) |block, i| {
        renderBlock(state, block, i);
    }
}

fn renderEmptyColumn(column_width: f32) void {
    var column = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = 1,
        .min_size_content = .{ .w = column_width },
        .max_size_content = .{ .w = column_width, .h = std.math.floatMax(f32) },
        .expand = .vertical,
        .background = false,
    });
    defer column.deinit();
}

fn renderBlock(state: *ReaderState, block: Block, id_extra: usize) void {
    switch (block.kind) {
        .separator => renderSeparator(id_extra),
        .image => renderImage(state, block.content, id_extra),
        .text => |style| renderTextBlock(block.content, style, id_extra),
    }
}

fn renderSeparator(id_extra: usize) void {
    var spacer_box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .padding = .{ .x = 80, .y = 16, .w = 80, .h = 16 },
        .background = false,
    });
    defer spacer_box.deinit();

    _ = dvui.separator(@src(), .{
        .expand = .horizontal,
        .min_size_content = .{ .h = 1 },
        .color_fill = mocha.base05,
        .background = true,
    });
}

fn renderTextBlock(content: []const u8, style: TextStyle, id_extra: usize) void {
    const padding = paddingForStyle(style);
    const font = fontForStyle(style);
    const text_color = colorForStyle(style);

    if (style == .blockquote) {
        var quote_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = id_extra,
            .expand = .horizontal,
            .background = true,
            .color_fill = mocha.base0D,
            .border = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
            .color_border = mocha.base0A,
            .padding = .{ .x = 20, .y = 14, .w = 20, .h = 14 },
            .margin = .{ .x = 16, .y = 12, .w = 28, .h = 12 },
            .corner_radius = .{ .x = 0, .y = 4, .w = 4, .h = 0 },
        });
        defer quote_box.deinit();

        var tl = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .background = false,
            .font = font,
            .color_text = text_color,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        });
        defer tl.deinit();
        tl.addText(content, .{});
        return;
    }

    if (style == .code) {
        var code_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = id_extra,
            .expand = .horizontal,
            .background = true,
            .color_fill = mocha.base0F,
            .border = dvui.Rect.all(1),
            .color_border = mocha.base08,
            .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
            .margin = .{ .x = 8, .y = 10, .w = 8, .h = 10 },
            .corner_radius = dvui.Rect.all(4),
        });
        defer code_box.deinit();

        var tl = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .background = false,
            .font = font,
            .color_text = text_color,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        });
        defer tl.deinit();
        tl.addText(content, .{});
        return;
    }

    if (style == .list_item) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = id_extra,
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 2, .w = 0, .h = 4 },
            .background = false,
        });
        defer row.deinit();

        dvui.label(@src(), "•", .{}, .{
            .font = font,
            .color_text = text_color,
            .padding = .{ .x = 0, .y = 0, .w = 10, .h = 0 },
            .gravity_y = 0,
        });

        var tl = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .background = false,
            .font = font,
            .color_text = text_color,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        });
        defer tl.deinit();
        tl.addText(content, .{});
        return;
    }

    var tl = dvui.textLayout(@src(), .{}, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .background = false,
        .font = font,
        .color_text = text_color,
        .padding = padding,
    });
    defer tl.deinit();
    tl.addText(content, .{});
}

fn renderImage(state: *ReaderState, filename: []const u8, id_extra: usize) void {
    const data = state.getImageData(filename) orelse {
        renderImageError(filename, id_extra);
        return;
    };

    const source = dvui.Texture.ImageSource{
        .imageFile = .{ .bytes = data, .name = filename },
    };

    const natural = dvui.imageSize(source) catch {
        renderImageError(filename, id_extra);
        return;
    };

    const available_w = @max(state.window_width - 60, 100);
    const display = computeImageDisplaySize(natural, available_w, image_max_height);

    var wrap = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = image_vertical_margin, .w = 0, .h = image_vertical_margin },
        .background = false,
    });
    defer wrap.deinit();

    _ = dvui.image(@src(), .{ .source = source }, .{
        .min_size_content = .{ .w = display.w, .h = display.h },
        .max_size_content = .{ .w = display.w, .h = display.h },
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .expand = .none,
    });
}

fn renderImageError(filename: []const u8, id_extra: usize) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[image: {s}]", .{filename}) catch "[image]";

    dvui.label(@src(), "{s}", .{msg}, .{
        .id_extra = id_extra,
        .font = fontForStyle(.caption),
        .color_text = mocha.base04,
        .padding = .{ .x = 0, .y = 8, .w = 0, .h = 8 },
    });
}

pub fn renderWelcome(state: *ReaderState) void {
    var center_box = dvui.box(@src(), .{}, .{
        .expand = .both,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .background = true,
        .color_fill = mocha.base07,
    });
    defer center_box.deinit();

    var welcome_box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .padding = dvui.Rect.all(40),
        .background = true,
        .color_fill = mocha.base0E,
        .corner_radius = dvui.Rect.all(8),
        .border = dvui.Rect.all(1),
        .color_border = mocha.base05,
    });
    defer welcome_box.deinit();

    if (state.error_message) |msg| {
        dvui.label(@src(), "{s}", .{msg}, .{
            .font = dvui.themeGet().font_body,
            .color_text = mocha.base0A,
        });
    } else {
        dvui.label(@src(), "Welcome to PubiX Reader", .{}, .{
            .font = dvui.themeGet().font_title,
            .color_text = mocha.base0A,
        });
        dvui.label(@src(), "", .{}, .{});
        dvui.label(@src(), "To open an EPUB file, restart with:", .{}, .{
            .color_text = mocha.base02,
        });
        dvui.label(@src(), "./app book.epub", .{}, .{
            .font = fontForStyle(.caption),
            .color_text = mocha.base03,
        });
        dvui.label(@src(), "", .{}, .{});
        dvui.label(@src(), "Navigation: H/L (pages) | K/J (chapters) | Q (quit)", .{}, .{
            .font = fontForStyle(.caption),
            .color_text = mocha.base04,
        });
    }
}
