const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("sdl-backend");
const parser = @import("../html/xhtml_parser.zig");
const tokenizer = @import("../html/xhtml_tokenizer.zig");
const fileReader = @import("../epub/file_reader.zig");

const EpubParser = fileReader.EpubParser;
const Chapter = fileReader.Chapter;
const ExtractedFile = fileReader.ExtractedFile;

const Page = struct {
    start_index: usize,
    end_index: usize,
    content: []const u8,
};

const ChapterPages = struct {
    pages: std.ArrayList(Page),
    current_page: usize,
    full_text: []u8,

    fn init() ChapterPages {
        return .{
            .pages = .{},
            .current_page = 0,
            .full_text = &.{},
        };
    }

    fn deinit(self: *ChapterPages, allocator: std.mem.Allocator) void {
        self.pages.deinit(allocator);
        if (self.full_text.len > 0) {
            allocator.free(self.full_text);
        }
    }
};

const ImageData = struct {
    filename: []const u8,
    data: []const u8,
};

const ReaderState = struct {
    allocator: std.mem.Allocator,
    epub: ?fileReader.Epub,
    chapters: ?std.ArrayList(Chapter),
    images: ?std.ArrayList(ExtractedFile),
    current_chapter: usize,
    chapter_pages: ChapterPages,
    error_message: ?[]const u8,
    window_height: f32,
    window_width: f32,
    content_height: f32,

    fn init(allocator: std.mem.Allocator) ReaderState {
        return .{
            .allocator = allocator,
            .epub = null,
            .chapters = null,
            .images = null,
            .current_chapter = 0,
            .chapter_pages = ChapterPages.init(),
            .error_message = null,
            .window_height = 600,
            .window_width = 800,
            .content_height = 500,
        };
    }

    fn deinit(self: *ReaderState) void {
        self.chapter_pages.deinit(self.allocator);

        if (self.images) |*images| {
            images.deinit(self.allocator);
        }

        if (self.chapters) |*chapters| {
            chapters.deinit(self.allocator);
        }
        if (self.epub) |*epub| {
            epub.deinit();
        }
    }

    fn loadEpub(self: *ReaderState, file_path: []const u8) !void {
        if (self.epub) |*epub| {
            epub.deinit();
            self.epub = null;
        }

        var epubParser = EpubParser.init(self.allocator);
        self.epub = epubParser.parseEpub(file_path) catch |err| {
            self.error_message = switch (err) {
                error.FileNotFound => "EPUB file not found",
                error.IsDir => "Path is a directory, not a file",
                error.AccessDenied => "Access denied to EPUB file",
                else => "Failed to load EPUB file",
            };
            return err;
        };

        if (self.epub) |*epub| {
            self.chapters = epub.getChapters() catch {
                self.error_message = "Failed to extract chapters";
                return error.ChapterExtractionFailed;
            };

            self.images = epub.getImages() catch blk: {
                std.log.warn("Failed to extract images", .{});
                break :blk null;
            };

            if (self.chapters) |chapters| {
                if (chapters.items.len > 0) {
                    self.current_chapter = 0;
                    try self.loadChapter(0);
                }
            }
        }
    }

    fn loadChapter(self: *ReaderState, index: usize) !void {
        if (self.chapters) |chapters| {
            if (index >= chapters.items.len) return;

            const chapter = chapters.items[index];
            self.current_chapter = index;

            const plain_text = try self.extractPlainTextWithImages(chapter.html_content);
            errdefer self.allocator.free(plain_text);

            try self.paginateText(plain_text);
        }
    }

    fn extractPlainTextWithImages(self: *ReaderState, html: []const u8) ![]u8 {
        const tokens = try tokenizer.tokenize(self.allocator, html);
        defer self.allocator.free(tokens);

        const tree = try parser.parse(self.allocator, tokens);
        defer tree.destroy(self.allocator);

        var text_list: std.ArrayList(u8) = .{};
        try self.extractTextFromNode(tree, &text_list);

        const raw_text = try text_list.toOwnedSlice(self.allocator);
        defer self.allocator.free(raw_text);

        return try self.cleanText(raw_text);
    }

    fn cleanText(self: *ReaderState, raw_text: []const u8) ![]u8 {
        var cleaned: std.ArrayList(u8) = .{};

        var i: usize = 0;
        while (i < raw_text.len) : (i += 1) {
            const char = raw_text[i];

            if (char == '\r') {
                continue;
            }

            if (char == '\n' or char == '\t' or (char >= 32 and char <= 126)) {
                try cleaned.append(self.allocator, char);
            } else if (char > 127) {
                try cleaned.append(self.allocator, char);
            }
        }

        return cleaned.toOwnedSlice(self.allocator);
    }

    fn extractTextFromNode(self: *ReaderState, node: *parser.Node, list: *std.ArrayList(u8)) !void {
        if (node.tag_name) |tag| {
            if (std.mem.eql(u8, tag, "img")) {
                if (node.attributes.count() > 0) {
                    var iter = node.attributes.iterator();
                    while (iter.next()) |entry| {
                        if (std.mem.eql(u8, entry.key_ptr.*, "src")) {
                            try list.appendSlice(self.allocator, "\n\n[IMG:");
                            try list.appendSlice(self.allocator, entry.value_ptr.*);
                            try list.appendSlice(self.allocator, "]\n\n");
                            var i: usize = 0;
                            while (i < 12) : (i += 1) {
                                try list.appendSlice(self.allocator, "\n");
                            }
                            return;
                        }
                    }
                }
            }
        }

        if (node.text_content) |text| {
            const trimmed = std.mem.trim(u8, text, " \n\r\t");
            if (trimmed.len > 0) {
                try list.appendSlice(self.allocator, trimmed);
                try list.append(self.allocator, ' ');
            }
        }

        if (node.tag_name) |tag| {
            if (std.mem.eql(u8, tag, "p") or std.mem.eql(u8, tag, "br")) {
                try list.appendSlice(self.allocator, "\n\n");
            } else if (std.mem.eql(u8, tag, "h1") or std.mem.eql(u8, tag, "h2") or
                std.mem.eql(u8, tag, "h3") or std.mem.eql(u8, tag, "h4"))
            {
                try list.appendSlice(self.allocator, "\n\n");
                for (node.children.items) |child| {
                    try self.extractTextFromNode(child, list);
                }
                try list.appendSlice(self.allocator, "\n\n");
                return;
            }
        }

        for (node.children.items) |child| {
            try self.extractTextFromNode(child, list);
        }
    }

    fn paginateText(self: *ReaderState, text: []u8) !void {
        self.chapter_pages.pages.clearAndFree(self.allocator);
        if (self.chapter_pages.full_text.len > 0) {
            self.allocator.free(self.chapter_pages.full_text);
        }

        self.chapter_pages.full_text = text;
        self.chapter_pages.current_page = 0;

        if (text.len == 0) {
            const page = Page{
                .start_index = 0,
                .end_index = 0,
                .content = "",
            };
            try self.chapter_pages.pages.append(self.allocator, page);
            return;
        }

        const window_area = self.window_width * self.window_height;
        const base_chars_per_page: f32 = 2200.0;
        const base_area: f32 = 480000.0;

        var chars_per_page = @as(usize, @intFromFloat((window_area / base_area) * base_chars_per_page));
        chars_per_page = @as(usize, @intFromFloat(@as(f32, @floatFromInt(chars_per_page)) * 0.5));
        chars_per_page = @min(chars_per_page, 3000);
        chars_per_page = @max(chars_per_page, 800);

        var start: usize = 0;
        while (start < text.len) {
            var end = @min(start + chars_per_page, text.len);

            if (end < text.len) {
                var found_break = false;

                if (end >= 2) {
                    var i = end;
                    const search_start = if (end > chars_per_page / 2) end - chars_per_page / 2 else start;
                    while (i > search_start and i > start + 1) : (i -= 1) {
                        if (text[i - 1] == '\n' and text[i - 2] == '\n') {
                            end = i;
                            found_break = true;
                            break;
                        }
                    }
                }

                if (!found_break and end > 0) {
                    var i = end;
                    const search_start = if (end > chars_per_page / 3) end - chars_per_page / 3 else start;
                    while (i > search_start and i > start) : (i -= 1) {
                        if (text[i - 1] == '\n') {
                            end = i;
                            found_break = true;
                            break;
                        }
                    }
                }

                if (!found_break and end > 0) {
                    var i = end;
                    const search_start = if (end > chars_per_page / 4) end - chars_per_page / 4 else start;
                    while (i > search_start and i > start) : (i -= 1) {
                        if (text[i - 1] == ' ') {
                            end = i;
                            break;
                        }
                    }
                }
            }

            const page = Page{
                .start_index = start,
                .end_index = end,
                .content = text[start..end],
            };

            try self.chapter_pages.pages.append(self.allocator, page);
            start = end;

            while (start < text.len and (text[start] == ' ' or text[start] == '\n')) {
                start += 1;
            }
        }

        if (self.chapter_pages.pages.items.len == 0) {
            const page = Page{
                .start_index = 0,
                .end_index = text.len,
                .content = text,
            };
            try self.chapter_pages.pages.append(self.allocator, page);
        }
    }

    fn nextPage(self: *ReaderState) void {
        if (self.chapter_pages.current_page + 1 < self.chapter_pages.pages.items.len) {
            self.chapter_pages.current_page += 1;
        } else {
            if (self.chapters) |chapters| {
                if (self.current_chapter + 1 < chapters.items.len) {
                    self.loadChapter(self.current_chapter + 1) catch {};
                }
            }
        }
    }

    fn prevPage(self: *ReaderState) void {
        if (self.chapter_pages.current_page > 0) {
            self.chapter_pages.current_page -= 1;
        } else {
            if (self.current_chapter > 0) {
                self.loadChapter(self.current_chapter - 1) catch {};
                if (self.chapter_pages.pages.items.len > 0) {
                    self.chapter_pages.current_page = self.chapter_pages.pages.items.len - 1;
                }
            }
        }
    }

    fn getImageData(self: *ReaderState, filename: []const u8) ?[]const u8 {
        if (self.images) |images| {
            for (images.items) |img| {
                if (std.mem.endsWith(u8, img.filename, filename) or std.mem.eql(u8, img.filename, filename)) {
                    return img.content;
                }
            }
        }
        return null;
    }
};

var g_state: ReaderState = undefined;
var g_backend: ?SDLBackend = null;

pub fn example(allocator: std.mem.Allocator, epub_file_path_param: ?[]const u8) !void {
    g_state = ReaderState.init(allocator);
    defer g_state.deinit();

    if (epub_file_path_param) |file_path| {
        g_state.loadEpub(file_path) catch |err| {
            std.log.err("Failed to load EPUB: {}", .{err});
        };
    }

    var backend = try SDLBackend.initWindow(.{
        .allocator = allocator,
        .size = .{ .w = 800, .h = 600 },
        .min_size = .{ .w = 400, .h = 300 },
        .vsync = false,
        .title = "PubiX Reader",
    });
    g_backend = backend;
    defer backend.deinit();

    var win = try dvui.Window.init(@src(), allocator, backend.backend(), .{});
    defer win.deinit();

    var interrupted = false;

    main_loop: while (true) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);

        const quit = try backend.addAllEvents(&win);
        if (quit) break :main_loop;

        _ = SDLBackend.c.SDL_SetRenderDrawColor(backend.renderer, 245, 245, 240, 255);
        _ = SDLBackend.c.SDL_RenderClear(backend.renderer);

        const window_rect = dvui.windowRect();
        const new_height = window_rect.h;
        const new_width = window_rect.w;

        if (@abs(new_height - g_state.window_height) > 20 or @abs(new_width - g_state.window_width) > 20) {
            g_state.window_height = new_height;
            g_state.window_width = new_width;
            g_state.content_height = new_height - 140;
            if (g_state.chapters != null and g_state.chapter_pages.full_text.len > 0) {
                const current_page = g_state.chapter_pages.current_page;
                g_state.loadChapter(g_state.current_chapter) catch {};
                if (current_page < g_state.chapter_pages.pages.items.len) {
                    g_state.chapter_pages.current_page = current_page;
                }
            }
        }

        const keep_running = gui_frame();
        if (!keep_running) break :main_loop;

        const end_micros = try win.end(.{});
        try backend.setCursor(win.cursorRequested());
        try backend.textInputRect(win.textInputRequested());
        try backend.renderPresent();

        const wait_event_micros = win.waitTime(end_micros);
        interrupted = try backend.waitEventTimeout(wait_event_micros);
    }
}

fn gui_frame() bool {
    const evts = dvui.events();
    for (evts) |*e| {
        if (e.evt == .key and e.evt.key.action == .down) {
            switch (e.evt.key.code) {
                .h, .left, .page_up => {
                    g_state.prevPage();
                    e.handled = true;
                },
                .l, .right, .page_down, .space => {
                    g_state.nextPage();
                    e.handled = true;
                },
                .k, .up => {
                    if (g_state.current_chapter > 0) {
                        g_state.loadChapter(g_state.current_chapter - 1) catch {};
                    }
                    e.handled = true;
                },
                .j, .down => {
                    if (g_state.chapters) |chapters| {
                        if (g_state.current_chapter + 1 < chapters.items.len) {
                            g_state.loadChapter(g_state.current_chapter + 1) catch {};
                        }
                    }
                    e.handled = true;
                },
                .q, .escape => {
                    e.handled = true;
                    return false;
                },
                else => {},
            }
        }
    }

    var main_vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
    });
    defer main_vbox.deinit();

    renderTopBar();

    if (g_state.chapters != null) {
        renderContent();
    } else {
        renderWelcome();
    }

    return true;
}

fn renderTopBar() void {
    var top_bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = 40 },
        .background = true,
        .padding = dvui.Rect.all(10),
        .border = dvui.Rect{ .x = 0, .y = 0, .w = 0, .h = 1 },
    });
    defer top_bar.deinit();

    if (g_state.chapters) |chapters| {
        if (g_state.current_chapter < chapters.items.len) {
            const chapter = chapters.items[g_state.current_chapter];

            var title_buf: [200]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buf, "Chapter {d}/{d}: {s} (Page {d}/{d})", .{
                g_state.current_chapter + 1,
                chapters.items.len,
                chapter.title,
                g_state.chapter_pages.current_page + 1,
                g_state.chapter_pages.pages.items.len,
            }) catch "Chapter";

            _ = dvui.label(@src(), "{s}", .{title}, .{ .font_style = .heading });
        }
    } else {
        _ = dvui.label(@src(), "PubiX Reader", .{}, .{ .font_style = .heading });
    }
}

fn renderContent() void {
    var content_box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .padding = dvui.Rect.all(30),
    });
    defer content_box.deinit();

    if (g_state.chapter_pages.pages.items.len > 0) {
        if (g_state.chapter_pages.current_page < g_state.chapter_pages.pages.items.len) {
            const page = g_state.chapter_pages.pages.items[g_state.chapter_pages.current_page];

            renderContentWithImages(page.content);
        }
    }
}

fn renderContentWithImages(content: []const u8) void {
    var pos: usize = 0;

    while (pos < content.len) {
        if (std.mem.indexOfPos(u8, content, pos, "[IMG:")) |img_start| {
            if (img_start > pos) {
                const text_before = content[pos..img_start];
                _ = dvui.label(@src(), "{s}", .{text_before}, .{
                    .font_style = .body,
                });
            }

            if (std.mem.indexOfPos(u8, content, img_start, "]")) |img_end| {
                const img_filename = content[img_start + 5 .. img_end];

                renderImage(img_filename);

                pos = img_end + 1;
            } else {
                pos = img_start + 5;
            }
        } else {
            const remaining_text = content[pos..];
            _ = dvui.label(@src(), "{s}", .{remaining_text}, .{
                .font_style = .body,
            });
            break;
        }
    }
}

fn renderImage(filename: []const u8) void {
    const img_data = g_state.getImageData(filename);

    if (img_data) |data| {
        const img_source = dvui.Texture.ImageSource{
            .imageFile = .{
                .bytes = data,
                .name = filename,
            },
        };

        _ = dvui.image(@src(), .{ .source = img_source }, .{
            .max_size_content = .{ .w = 500, .h = 300 },
        });
    } else {
        showImageError(filename);
    }
}

fn showImageError(filename: []const u8) void {
    var img_label_buf: [256]u8 = undefined;
    const img_label = std.fmt.bufPrint(&img_label_buf, "[Image error: {s}]", .{filename}) catch "[Image error]";

    _ = dvui.label(@src(), "{s}", .{img_label}, .{
        .font_style = .caption,
        .color_text = dvui.Color{ .r = 0xFF, .g = 0x66, .b = 0x66, .a = 0xFF },
    });
}

fn renderWelcome() void {
    var center_box = dvui.box(@src(), .{}, .{
        .expand = .both,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .background = true,
    });
    defer center_box.deinit();

    var welcome_box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .padding = dvui.Rect.all(40),
        .background = true,
        .corner_radius = dvui.Rect.all(8),
    });
    defer welcome_box.deinit();

    if (g_state.error_message) |msg| {
        _ = dvui.label(@src(), "{s}", .{msg}, .{ .font_style = .body });
    } else {
        _ = dvui.label(@src(), "Welcome to PubiX Reader", .{}, .{ .font_style = .heading });
        _ = dvui.label(@src(), "", .{}, .{});
        _ = dvui.label(@src(), "To open an EPUB file, restart with:", .{}, .{});
        _ = dvui.label(@src(), "./app book.epub", .{}, .{ .font_style = .caption });
        _ = dvui.label(@src(), "", .{}, .{});
        _ = dvui.label(@src(), "Navigation: H/L (pages) | K/J (chapters) | Q (quit)", .{}, .{ .font_style = .caption });
    }
}
