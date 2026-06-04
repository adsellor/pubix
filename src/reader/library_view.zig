const std = @import("std");
const dvui = @import("dvui");

const theme_mod = @import("theme.zig");
const block_mod = @import("block.zig");
const state_mod = @import("state.zig");

const mocha = theme_mod.mocha;
const fontForStyle = block_mod.fontForStyle;
const ReaderState = state_mod.ReaderState;
const PendingAction = state_mod.PendingAction;

pub fn render(state: *ReaderState) void {
    renderTopBar(state);
    renderBody(state);
}

fn renderTopBar(state: *ReaderState) void {
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

    dvui.label(@src(), "PubiX Library", .{}, .{
        .font = dvui.themeGet().font_heading,
        .color_text = mocha.base00,
        .gravity_y = 0.5,
        .expand = .horizontal,
    });

    if (dvui.button(@src(), "Add Book", .{}, .{
        .font = fontForStyle(.caption),
        .color_text = mocha.base00,
        .color_fill = mocha.base09,
        .padding = .{ .x = 14, .y = 6, .w = 14, .h = 6 },
        .corner_radius = dvui.Rect.all(4),
        .gravity_y = 0.5,
    })) {
        state.pending_action = .add_book;
    }
}

fn renderBody(state: *ReaderState) void {
    var content = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = mocha.base07,
        .padding = .{ .x = 32, .y = 24, .w = 32, .h = 24 },
    });
    defer content.deinit();

    if (state.library.books.items.len == 0) {
        renderEmpty();
        return;
    }

    const indices = state.library.sortedIndices();

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    for (indices, 0..) |book_idx, slot| {
        renderBookRow(state, book_idx, slot);
    }
}

fn renderEmpty() void {
    var center = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
    defer center.deinit();

    dvui.label(@src(), "No books yet — click 'Add Book' to import an EPUB.", .{}, .{
        .font = dvui.themeGet().font_body,
        .color_text = mocha.base03,
        .gravity_x = 0.5,
    });
}

fn renderBookRow(state: *ReaderState, book_idx: usize, slot: usize) void {
    const book = state.library.books.items[book_idx];

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = slot,
        .expand = .horizontal,
        .background = true,
        .color_fill = mocha.base0E,
        .border = dvui.Rect.all(1),
        .color_border = mocha.base05,
        .corner_radius = dvui.Rect.all(4),
        .padding = .{ .x = 14, .y = 12, .w = 14, .h = 12 },
        .margin = .{ .x = 0, .y = 6, .w = 0, .h = 6 },
    });
    defer row.deinit();

    renderCover(book, slot);

    var info = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = slot,
        .expand = .horizontal,
        .padding = .{ .x = 14, .y = 0, .w = 0, .h = 0 },
        .background = false,
    });
    defer info.deinit();

    if (dvui.labelClick(@src(), "{s}", .{book.title}, .{}, .{
        .font = dvui.themeGet().font_heading,
        .color_text = mocha.base00,
        .expand = .horizontal,
    })) {
        state.pending_action = .{ .open_book = book_idx };
    }

    if (book.author) |a| {
        dvui.label(@src(), "by {s}", .{a}, .{
            .font = fontForStyle(.caption),
            .color_text = mocha.base03,
            .expand = .horizontal,
        });
    }

    var progress_buf: [128]u8 = undefined;
    const progress_text = if (book.last_opened == 0)
        "Not opened yet"
    else
        std.fmt.bufPrint(&progress_buf, "Chapter {d} of {d} · Page {d}", .{
            book.last_chapter + 1,
            book.chapter_count,
            book.last_page + 1,
        }) catch "";

    dvui.label(@src(), "{s}", .{progress_text}, .{
        .font = fontForStyle(.caption),
        .color_text = mocha.base04,
        .expand = .horizontal,
    });
}

const cover_width: f32 = 64;
const cover_height: f32 = 96;

fn renderCover(book: state_mod.BookEntry, slot: usize) void {
    if (book.cover_bytes) |bytes| {
        const source = dvui.Texture.ImageSource{
            .imageFile = .{ .bytes = bytes, .name = book.path },
        };
        const natural = dvui.imageSize(source) catch {
            renderCoverPlaceholder(slot);
            return;
        };
        const display = fitInBox(natural, cover_width, cover_height);

        var holder = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = slot,
            .min_size_content = .{ .w = cover_width, .h = cover_height },
            .max_size_content = .{ .w = cover_width, .h = cover_height },
            .background = false,
        });
        defer holder.deinit();

        _ = dvui.image(@src(), .{ .source = source }, .{
            .min_size_content = .{ .w = display.w, .h = display.h },
            .max_size_content = .{ .w = display.w, .h = display.h },
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .expand = .none,
        });
        return;
    }
    renderCoverPlaceholder(slot);
}

fn renderCoverPlaceholder(slot: usize) void {
    var placeholder = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = slot,
        .min_size_content = .{ .w = cover_width, .h = cover_height },
        .max_size_content = .{ .w = cover_width, .h = cover_height },
        .background = true,
        .color_fill = mocha.base07,
        .border = dvui.Rect.all(1),
        .color_border = mocha.base05,
        .corner_radius = dvui.Rect.all(2),
    });
    defer placeholder.deinit();

    dvui.label(@src(), "·", .{}, .{
        .color_text = mocha.base04,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
}

fn fitInBox(natural: dvui.Size, max_w: f32, max_h: f32) dvui.Size {
    if (natural.w <= 0 or natural.h <= 0) return .{ .w = max_w, .h = max_h };
    var w = natural.w;
    var h = natural.h;
    if (w > max_w) {
        const s = max_w / w;
        w = max_w;
        h *= s;
    }
    if (h > max_h) {
        const s = max_h / h;
        h = max_h;
        w *= s;
    }
    return .{ .w = w, .h = h };
}
