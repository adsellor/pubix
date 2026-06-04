const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("sdl-backend");

const theme_mod = @import("theme.zig");
const mocha = theme_mod.mocha;
const mocha_theme = theme_mod.mocha_theme;

const layout_mod = @import("layout.zig");
const computeLayout = layout_mod.computeLayout;
const computeColumnWidth = layout_mod.computeColumnWidth;

const state_mod = @import("state.zig");
const ReaderState = state_mod.ReaderState;
const PendingAction = state_mod.PendingAction;

const render = @import("render.zig");
const library_view = @import("library_view.zig");
const library_mod = @import("library.zig");

const fileReader = @import("../epub/file_reader.zig");

var g_state: ReaderState = undefined;
var g_backend: ?SDLBackend = null;
var metrics_settled: bool = false;

pub fn example(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    epub_file_path_param: ?[]const u8,
) !void {
    g_state = try ReaderState.init(allocator, io, environ);
    defer g_state.deinit();
    defer saveProgressOnExit();

    if (epub_file_path_param) |file_path| {
        const absolute = std.Io.Dir.path.isAbsolute(file_path);
        const path_to_use = if (absolute) try allocator.dupe(u8, file_path) else try absolutize(allocator, file_path);
        defer allocator.free(path_to_use);

        g_state.mode = .reader;
        g_state.startBackgroundLoad(path_to_use, 0, 0, true) catch |err| {
            std.log.err("Failed to start load: {}", .{err});
        };
    }

    var backend = try SDLBackend.initWindow(.{
        .io = io,
        .size = .{ .w = 800, .h = 600 },
        .min_size = .{ .w = 400, .h = 300 },
        .vsync = false,
        .title = "PubiX Reader",
    });
    g_backend = backend;
    defer backend.deinit();

    var window_open = true;
    var win = try dvui.Window.init(@src(), allocator, backend.backend(), .{
        .theme = mocha_theme,
        .open_flag = &window_open,
    });
    defer win.deinit();

    var interrupted = false;

    main_loop: while (window_open) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);

        try backend.addAllEvents(&win);

        const window_rect = dvui.windowRect();
        const new_height = window_rect.h;
        const new_width = window_rect.w;

        const size_changed = @abs(new_width - g_state.chapter_pages.paginated_width) > 20 or
            @abs(new_height - g_state.chapter_pages.paginated_height) > 20;

        g_state.window_width = new_width;
        g_state.window_height = new_height;

        if (size_changed) {
            const new_layout = computeLayout(new_width);
            const new_column_width = computeColumnWidth(new_width, new_layout);
            const layout_changed = new_layout != g_state.chapter_pages.layout;
            const column_changed = @abs(new_column_width - g_state.chapter_pages.paginated_column_width) > 5;
            if (layout_changed or column_changed) {
                g_state.chapter_pages.layout = new_layout;
                g_state.chapter_pages.needs_pagination = true;
            }
        }

        const keep_running = gui_frame();
        if (!keep_running) break :main_loop;

        const end_micros = (try win.end(.{})) orelse 0;

        const wait_event_micros = win.waitTime(end_micros);
        interrupted = try backend.waitEventTimeout(wait_event_micros);
    }
}

fn gui_frame() bool {
    const evts = dvui.events();
    for (evts) |*e| {
        if (e.evt == .key and e.evt.key.action == .down) {
            switch (e.evt.key.code) {
                .q, .escape => {
                    if (g_state.mode == .reader) {
                        backToLibrary();
                    } else {
                        e.handled = true;
                        return false;
                    }
                    e.handled = true;
                },
                .b => {
                    if (g_state.mode == .reader) {
                        backToLibrary();
                        e.handled = true;
                    }
                },
                .h, .left, .page_up => {
                    if (g_state.mode == .reader) {
                        g_state.prevPage();
                        e.handled = true;
                    }
                },
                .l, .right, .page_down, .space => {
                    if (g_state.mode == .reader) {
                        g_state.nextPage();
                        e.handled = true;
                    }
                },
                .k, .up => {
                    if (g_state.mode == .reader and g_state.current_chapter > 0) {
                        g_state.loadChapter(g_state.current_chapter - 1) catch {};
                        e.handled = true;
                    }
                },
                .j, .down => {
                    if (g_state.mode == .reader) {
                        if (g_state.chapters) |chapters| {
                            if (g_state.current_chapter + 1 < chapters.items.len) {
                                g_state.loadChapter(g_state.current_chapter + 1) catch {};
                            }
                        }
                        e.handled = true;
                    }
                },
                else => {},
            }
        }
    }

    if (metrics_settled and g_state.mode == .reader and g_state.chapter_pages.needs_pagination and g_state.chapter_pages.blocks.len > 0) {
        g_state.paginate() catch {};
        applyPostPaginationAdjustments();
    }

    finalizeLoadIfReady();

    const load_state_now = g_state.load_state.load(.acquire);
    const is_loading = load_state_now == @intFromEnum(state_mod.LoadState.loading);

    {
        var main_vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = true,
            .color_fill = mocha.base07,
        });
        defer main_vbox.deinit();

        switch (g_state.mode) {
            .library => library_view.render(&g_state),
            .reader => {
                if (is_loading) {
                    renderLoadingScreen();
                } else {
                    render.renderTopBar(&g_state);
                    if (g_state.chapters != null) {
                        render.renderContent(&g_state);
                    } else {
                        render.renderWelcome(&g_state);
                    }
                }
            },
        }
    }

    if (is_loading) {
        dvui.refresh(null, @src(), null);
    }

    if (!metrics_settled and g_state.mode == .reader) {
        if (g_state.chapter_pages.needs_pagination and g_state.chapter_pages.blocks.len > 0) {
            g_state.paginate() catch {};
            applyPostPaginationAdjustments();
        }
        metrics_settled = true;
        dvui.refresh(null, @src(), null);
    }

    if (g_state.pending_action) |action| {
        g_state.pending_action = null;
        handleAction(action);
    }

    return true;
}

fn finalizeLoadIfReady() void {
    const ls = g_state.load_state.load(.acquire);
    if (ls == @intFromEnum(state_mod.LoadState.ready)) {
        g_state.awaitBackgroundLoad();
        g_state.load_state.store(@intFromEnum(state_mod.LoadState.idle), .release);

        if (g_state.load_request_add_to_library) {
            if (g_state.chapters) |chapters| {
                const path = g_state.load_path orelse return;
                const title = if (g_state.epub) |ep| (ep.metadata.title orelse titleFromPath(path)) else titleFromPath(path);
                const author = if (g_state.epub) |ep| ep.metadata.creator else null;
                const idx = g_state.library.addBook(path, title, author, chapters.items.len) catch return;
                g_state.active_book_idx = idx;

                if (g_state.library.books.items[idx].cover_path == null) {
                    if (g_state.epub) |*ep| {
                        if (library_mod.extractCoverFromEpub(g_state.allocator, ep) catch null) |cover| {
                            defer g_state.allocator.free(cover);
                            g_state.library.attachCover(g_state.io, idx, cover) catch |err| std.log.warn("library: attachCover failed: {t}", .{err});
                        }
                    }
                }
                const last_chapter = g_state.library.books.items[idx].last_chapter;
                const last_page = g_state.library.books.items[idx].last_page;
                if (last_chapter > 0) g_state.loadChapter(last_chapter) catch {};
                g_state.pending_target_page = last_page;
                g_state.library.touchOpenedAt(idx, nowUnixSeconds());
                g_state.library.save(g_state.io) catch |err| std.log.warn("library: save failed: {t}", .{err});
            }
        } else {
            if (g_state.load_target_chapter > 0) {
                g_state.loadChapter(g_state.load_target_chapter) catch {};
            }
            g_state.pending_target_page = g_state.load_target_page;
        }

        metrics_settled = false;
    } else if (ls == @intFromEnum(state_mod.LoadState.failure)) {
        g_state.awaitBackgroundLoad();
        g_state.load_state.store(@intFromEnum(state_mod.LoadState.idle), .release);
        g_state.mode = .library;
    }
}

fn renderLoadingScreen() void {
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

    var loading_buf: [256]u8 = undefined;
    const label_text: []const u8 = blk: {
        if (g_state.active_book_idx) |idx| {
            if (idx < g_state.library.books.items.len) {
                break :blk std.fmt.bufPrint(&loading_buf, "Loading: {s}", .{g_state.library.books.items[idx].title}) catch "Loading…";
            }
        }
        break :blk "Loading…";
    };

    dvui.label(@src(), "{s}", .{label_text}, .{
        .font = dvui.themeGet().font_heading,
        .color_text = mocha.base00,
        .gravity_y = 0.5,
        .gravity_x = 0.5,
        .expand = .horizontal,
    });
}

fn applyPostPaginationAdjustments() void {
    if (g_state.chapter_pages.pages.items.len == 0) return;
    if (g_state.chapter_pages.goto_last_page) {
        g_state.chapter_pages.current_page = g_state.chapter_pages.pages.items.len - 1;
        g_state.chapter_pages.goto_last_page = false;
    }
    if (g_state.pending_target_page) |target| {
        var page = @min(target, g_state.chapter_pages.pages.items.len - 1);
        if (g_state.chapter_pages.layout == .double and page % 2 != 0) page -= 1;
        g_state.chapter_pages.current_page = page;
        g_state.pending_target_page = null;
    }
}

fn saveProgressOnExit() void {
    if (g_state.mode != .reader) return;
    const idx = g_state.active_book_idx orelse return;
    g_state.library.updateProgress(idx, g_state.current_chapter, g_state.chapter_pages.current_page, nowUnixSeconds());
    g_state.library.save(g_state.io) catch |err| std.log.warn("library: save failed: {t}", .{err});
}

fn backToLibrary() void {
    if (g_state.active_book_idx) |idx| {
        const now = nowUnixSeconds();
        g_state.library.updateProgress(idx, g_state.current_chapter, g_state.chapter_pages.current_page, now);
        g_state.library.save(g_state.io) catch |err| std.log.warn("library: save failed: {t}", .{err});
    }
    g_state.mode = .library;
}

fn handleAction(action: state_mod.PendingAction) void {
    switch (action) {
        .add_book => addBookFromDialog(),
        .open_book => |idx| openBook(idx),
    }
}

fn addBookFromDialog() void {
    const path = dvui.dialogNativeFileOpen(g_state.allocator, .{
        .title = "Open EPUB",
        .filters = &.{"*.epub"},
        .filter_description = "EPUB files",
    }) catch |err| {
        std.log.warn("file dialog failed: {t}", .{err});
        return;
    } orelse return;
    defer g_state.allocator.free(path);

    var parser = fileReader.EpubParser.init(g_state.allocator, g_state.io);
    var epub = parser.parseEpub(path) catch |err| {
        std.log.warn("failed to parse EPUB '{s}': {t}", .{ path, err });
        return;
    };
    defer epub.deinit();

    var chapter_list = epub.getChapters() catch {
        std.log.warn("failed to get chapters from '{s}'", .{path});
        return;
    };
    defer {
        for (chapter_list.items) |*c| c.deinit(g_state.allocator);
        chapter_list.deinit(g_state.allocator);
    }

    const title = if (epub.metadata.title) |t| t else titleFromPath(path);
    const author = epub.metadata.creator;

    const idx = g_state.library.addBook(path, title, author, chapter_list.items.len) catch |err| {
        std.log.warn("library: addBook failed: {t}", .{err});
        return;
    };
    if (g_state.library.books.items[idx].cover_path == null) {
        if (library_mod.extractCoverFromEpub(g_state.allocator, &epub) catch null) |cover| {
            defer g_state.allocator.free(cover);
            g_state.library.attachCover(g_state.io, idx, cover) catch |err| std.log.warn("library: attachCover failed: {t}", .{err});
        }
    }
    g_state.library.save(g_state.io) catch |err| std.log.warn("library: save failed: {t}", .{err});
}

fn openBook(idx: usize) void {
    if (idx >= g_state.library.books.items.len) return;
    const path = g_state.library.books.items[idx].path;
    const last_chapter = g_state.library.books.items[idx].last_chapter;
    const last_page = g_state.library.books.items[idx].last_page;

    g_state.active_book_idx = idx;
    g_state.mode = .reader;
    metrics_settled = false;

    g_state.startBackgroundLoad(path, last_chapter, last_page, false) catch |err| {
        std.log.warn("failed to start load '{s}': {t}", .{ path, err });
        return;
    };

    g_state.library.touchOpenedAt(idx, nowUnixSeconds());
    g_state.library.save(g_state.io) catch |err| std.log.warn("library: save failed: {t}", .{err});
}

fn absolutize(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try std.process.currentPath(g_state.io, &cwd_buf);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd_buf[0..cwd], path });
}

fn nowUnixSeconds() i64 {
    return std.Io.Clock.now(.real, g_state.io).toSeconds();
}

fn titleFromPath(path: []const u8) []const u8 {
    const base = std.Io.Dir.path.basename(path);
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| return base[0..dot];
    return base;
}
