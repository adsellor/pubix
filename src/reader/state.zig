const std = @import("std");
const dvui = @import("dvui");
const parser = @import("../html/xhtml_parser.zig");
const tokenizer = @import("../html/xhtml_tokenizer.zig");
const fileReader = @import("../epub/file_reader.zig");

const block_mod = @import("block.zig");
const extract_mod = @import("extract.zig");
const layout_mod = @import("layout.zig");
const library_mod = @import("library.zig");
const parse_cache = @import("parse_cache.zig");

pub const Library = library_mod.Library;
pub const BookEntry = library_mod.BookEntry;
pub const AppMode = enum { library, reader };

pub const LoadState = enum(u8) {
    idle = 0,
    loading = 1,
    ready = 2,
    failure = 3,
};

pub const PendingAction = union(enum) {
    add_book,
    open_book: usize,
};

const EpubParser = fileReader.EpubParser;
const Chapter = fileReader.Chapter;
const ExtractedFile = fileReader.ExtractedFile;

const Block = block_mod.Block;
const TextStyle = block_mod.TextStyle;
const PageRange = block_mod.PageRange;
const isHeadingBlock = block_mod.isHeadingBlock;
const fontForStyle = block_mod.fontForStyle;
const paddingForStyle = block_mod.paddingForStyle;

const BlockExtractCtx = extract_mod.BlockExtractCtx;

const Layout = layout_mod.Layout;
const computeColumnWidth = layout_mod.computeColumnWidth;
const computeImageDisplaySize = layout_mod.computeImageDisplaySize;
const top_bar_height = layout_mod.top_bar_height;
const image_max_height = layout_mod.image_max_height;
const image_vertical_margin = layout_mod.image_vertical_margin;

pub const ParsedChapter = struct {
    arena: std.heap.ArenaAllocator,
    blocks: []const Block,

    pub fn empty(parent: std.mem.Allocator) ParsedChapter {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent),
            .blocks = &.{},
        };
    }

    pub fn deinit(self: *ParsedChapter) void {
        self.arena.deinit();
    }
};

pub const ChapterPages = struct {
    blocks: []const Block,
    pages: std.ArrayList(PageRange),
    current_page: usize,
    needs_pagination: bool,
    goto_last_page: bool,
    paginated_width: f32,
    paginated_height: f32,
    paginated_column_width: f32,
    layout: Layout,

    pub fn init() ChapterPages {
        return .{
            .blocks = &.{},
            .pages = .empty,
            .current_page = 0,
            .needs_pagination = false,
            .goto_last_page = false,
            .paginated_width = 0,
            .paginated_height = 0,
            .paginated_column_width = 0,
            .layout = .single,
        };
    }

    pub fn deinit(self: *ChapterPages, allocator: std.mem.Allocator) void {
        self.pages.deinit(allocator);
    }

    pub fn reset(self: *ChapterPages) void {
        self.blocks = &.{};
        self.pages.clearRetainingCapacity();
        self.current_page = 0;
        self.goto_last_page = false;
    }
};

pub fn parseChapterHtml(parent_allocator: std.mem.Allocator, html: []const u8) !ParsedChapter {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const tokens = try tokenizer.tokenize(arena_alloc, html);
    const tree = try parser.parse(arena_alloc, tokens);

    var blocks: std.ArrayList(Block) = .empty;
    var ctx = BlockExtractCtx{
        .allocator = arena_alloc,
        .blocks = &blocks,
        .current_text = .empty,
        .style_stack = .empty,
        .container_depth = 0,
    };

    try ctx.style_stack.append(arena_alloc, .body);
    try ctx.walk(tree);
    try ctx.flushText();

    const blocks_slice = try blocks.toOwnedSlice(arena_alloc);
    return .{ .arena = arena, .blocks = blocks_slice };
}

pub const chapter_state_unparsed: u8 = 0;
pub const chapter_state_parsing: u8 = 1;
pub const chapter_state_done: u8 = 2;

fn loadBookBg(self: *ReaderState, path: []const u8) std.Io.Cancelable!void {
    self.loadEpubInline(path) catch |err| {
        std.log.warn("background load failed: {t}", .{err});
        self.load_error_msg = "Failed to load EPUB";
        self.load_state.store(@intFromEnum(LoadState.failure), .release);
        return;
    };
    self.load_state.store(@intFromEnum(LoadState.ready), .release);
}

fn parseChapterTask(
    parent_allocator: std.mem.Allocator,
    html: []const u8,
    slot: *ParsedChapter,
    state: *std.atomic.Value(u8),
    dirty: *std.atomic.Value(bool),
) std.Io.Cancelable!void {
    if (state.cmpxchgStrong(chapter_state_unparsed, chapter_state_parsing, .acq_rel, .acquire) != null) {
        return;
    }
    const parsed = parseChapterHtml(parent_allocator, html) catch {
        state.store(chapter_state_unparsed, .release);
        return;
    };
    slot.deinit();
    slot.* = parsed;
    state.store(chapter_state_done, .release);
    dirty.store(true, .release);
}

pub const ReaderState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    library: Library,
    mode: AppMode,
    active_book_idx: ?usize,
    epub: ?fileReader.Epub,
    chapters: ?std.ArrayList(Chapter),
    images: ?std.ArrayList(ExtractedFile),
    parsed_chapters: ?std.ArrayList(ParsedChapter),
    chapter_states: []std.atomic.Value(u8),
    parse_group: std.Io.Group,
    parse_group_active: bool,
    cache_path: ?[]const u8,
    cache_dirty: std.atomic.Value(bool),
    cache_view: ?parse_cache.CacheView,
    epub_mtime_ns: i128,
    environ: *std.process.Environ.Map,
    load_state: std.atomic.Value(u8),
    load_future: ?std.Io.Future(std.Io.Cancelable!void),
    load_path: ?[]u8,
    load_error_msg: ?[]const u8,
    load_target_chapter: usize,
    load_target_page: usize,
    load_request_add_to_library: bool,
    load_added_library_idx: ?usize,
    current_chapter: usize,
    chapter_pages: ChapterPages,
    error_message: ?[]const u8,
    window_height: f32,
    window_width: f32,
    pending_action: ?PendingAction,
    pending_target_page: ?usize,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map) !ReaderState {
        const library = try Library.init(allocator, io, environ);
        return .{
            .allocator = allocator,
            .io = io,
            .library = library,
            .mode = .library,
            .active_book_idx = null,
            .epub = null,
            .chapters = null,
            .images = null,
            .parsed_chapters = null,
            .chapter_states = &.{},
            .parse_group = .init,
            .parse_group_active = false,
            .cache_path = null,
            .cache_dirty = std.atomic.Value(bool).init(false),
            .cache_view = null,
            .epub_mtime_ns = 0,
            .environ = environ,
            .load_state = std.atomic.Value(u8).init(@intFromEnum(LoadState.idle)),
            .load_future = null,
            .load_path = null,
            .load_error_msg = null,
            .load_target_chapter = 0,
            .load_target_page = 0,
            .load_request_add_to_library = false,
            .load_added_library_idx = null,
            .current_chapter = 0,
            .chapter_pages = ChapterPages.init(),
            .error_message = null,
            .window_height = 600,
            .window_width = 800,
            .pending_action = null,
            .pending_target_page = null,
        };
    }

    pub fn deinit(self: *ReaderState) void {
        self.awaitBackgroundLoad();

        if (self.parse_group_active) {
            self.parse_group.await(self.io) catch {};
            self.parse_group_active = false;
        }

        self.flushParseCache();

        self.library.deinit();
        self.chapter_pages.deinit(self.allocator);

        if (self.parsed_chapters) |*pc| {
            for (pc.items) |*p| p.deinit();
            pc.deinit(self.allocator);
        }

        if (self.chapter_states.len > 0) {
            self.allocator.free(self.chapter_states);
            self.chapter_states = &.{};
        }

        if (self.cache_path) |p| {
            self.allocator.free(p);
            self.cache_path = null;
        }

        if (self.cache_view) |*cv| {
            cv.deinit(self.io);
            self.cache_view = null;
        }

        if (self.load_path) |p| {
            self.allocator.free(p);
            self.load_path = null;
        }

        if (self.images) |*images| {
            images.deinit(self.allocator);
        }

        if (self.chapters) |*chapters| {
            for (chapters.items) |*chapter| {
                chapter.deinit(self.allocator);
            }
            chapters.deinit(self.allocator);
        }
        if (self.epub) |*epub| {
            epub.deinit();
        }
    }

    pub fn awaitBackgroundLoad(self: *ReaderState) void {
        if (self.load_future) |*fut| {
            fut.await(self.io) catch {};
            self.load_future = null;
        }
    }

    pub fn startBackgroundLoad(
        self: *ReaderState,
        path: []const u8,
        target_chapter: usize,
        target_page: usize,
        add_to_library: bool,
    ) !void {
        self.awaitBackgroundLoad();

        const path_copy = try self.allocator.dupe(u8, path);
        if (self.load_path) |old| self.allocator.free(old);
        self.load_path = path_copy;
        self.load_target_chapter = target_chapter;
        self.load_target_page = target_page;
        self.load_request_add_to_library = add_to_library;
        self.load_added_library_idx = null;
        self.load_error_msg = null;
        self.load_state.store(@intFromEnum(LoadState.loading), .release);

        if (std.Io.concurrent(self.io, loadBookBg, .{ self, path_copy })) |fut| {
            self.load_future = fut;
        } else |err| switch (err) {
            error.ConcurrencyUnavailable => {
                _ = loadBookBg(self, path_copy) catch {};
            },
        }
    }

    fn loadEpubInline(self: *ReaderState, file_path: []const u8) !void {
        if (self.epub) |*epub| {
            epub.deinit();
            self.epub = null;
        }

        if (self.cache_path) |old| {
            self.allocator.free(old);
            self.cache_path = null;
        }

        const stat = std.Io.Dir.cwd().statFile(self.io, file_path, .{}) catch null;
        self.epub_mtime_ns = if (stat) |s| s.mtime.toNanoseconds() else 0;

        self.cache_path = parse_cache.cachePath(self.allocator, self.environ, file_path) catch null;
        self.cache_dirty.store(false, .release);

        if (self.tryLoadFullyFromCache() catch false) {
            if (self.chapters) |chapters| {
                if (chapters.items.len > 0) {
                    self.current_chapter = 0;
                    try self.loadChapter(0);
                }
            }
            return;
        }

        var epubParser = EpubParser.init(self.allocator, self.io);
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

            try self.kickBackgroundParsing();

            if (self.chapters) |chapters| {
                if (chapters.items.len > 0) {
                    self.current_chapter = 0;
                    try self.loadChapter(0);
                }
            }
        }
    }

    fn tryLoadFullyFromCache(self: *ReaderState) !bool {
        const cache_path = self.cache_path orelse return false;

        var view = (try parse_cache.openCache(self.io, cache_path, self.epub_mtime_ns)) orelse return false;
        errdefer view.deinit(self.io);

        const ch_count = view.chapterCount();
        if (ch_count == 0) {
            view.deinit(self.io);
            return false;
        }

        var chapters: std.ArrayList(Chapter) = .empty;
        errdefer chapters.deinit(self.allocator);
        try chapters.ensureTotalCapacity(self.allocator, ch_count);
        for (0..ch_count) |i| {
            const title_slice = view.chapterTitle(i) orelse return error.CacheCorrupt;
            try chapters.append(self.allocator, .{
                .title = title_slice,
                .html_content = "",
                .filename = "",
                .chapter_number = i + 1,
                .owned = false,
            });
        }

        var images: std.ArrayList(ExtractedFile) = .empty;
        errdefer images.deinit(self.allocator);
        try images.ensureTotalCapacity(self.allocator, view.imageCount());
        for (0..view.imageCount()) |i| {
            const ref = view.imageRef(i) orelse return error.CacheCorrupt;
            try images.append(self.allocator, .{ .filename = ref.filename, .content = ref.content });
        }

        var parsed: std.ArrayList(ParsedChapter) = .empty;
        errdefer {
            for (parsed.items) |*p| p.deinit();
            parsed.deinit(self.allocator);
        }
        try parsed.ensureTotalCapacity(self.allocator, ch_count);
        for (0..ch_count) |_| {
            try parsed.append(self.allocator, ParsedChapter.empty(self.allocator));
        }

        const states = try self.allocator.alloc(std.atomic.Value(u8), ch_count);
        errdefer self.allocator.free(states);
        for (states) |*s| s.* = std.atomic.Value(u8).init(chapter_state_done);

        for (parsed.items, 0..) |*slot, idx| {
            const payload = view.chapterPayload(idx) orelse return error.CacheCorrupt;
            const arena_alloc = slot.arena.allocator();
            const blocks = try parse_cache.decodeChapter(payload, arena_alloc);
            slot.blocks = blocks;
        }

        self.chapters = chapters;
        self.images = images;
        self.parsed_chapters = parsed;
        self.chapter_states = states;
        self.cache_view = view;
        return true;
    }

    fn flushParseCache(self: *ReaderState) void {
        if (!self.cache_dirty.load(.acquire)) return;
        const cache_path = self.cache_path orelse return;
        const pc = self.parsed_chapters orelse return;
        const chapters = self.chapters orelse return;
        if (pc.items.len == 0) return;

        var per_chapter_blocks = self.allocator.alloc([]const Block, pc.items.len) catch return;
        defer self.allocator.free(per_chapter_blocks);
        for (pc.items, 0..) |entry, i| per_chapter_blocks[i] = entry.blocks;

        var chapter_titles = self.allocator.alloc([]const u8, chapters.items.len) catch return;
        defer self.allocator.free(chapter_titles);
        for (chapters.items, 0..) |c, i| chapter_titles[i] = c.title;

        var image_refs: std.ArrayList(parse_cache.ImageRef) = .empty;
        defer image_refs.deinit(self.allocator);
        if (self.images) |imgs| {
            image_refs.ensureTotalCapacity(self.allocator, imgs.items.len) catch return;
            for (imgs.items) |img| {
                image_refs.append(self.allocator, .{ .filename = img.filename, .content = img.content }) catch return;
            }
        }

        parse_cache.writeCache(self.io, cache_path, self.epub_mtime_ns, per_chapter_blocks, chapter_titles, image_refs.items) catch |err| {
            std.log.warn("parse_cache: writeCache failed: {t}", .{err});
            return;
        };
        self.cache_dirty.store(false, .release);
    }

    fn kickBackgroundParsing(self: *ReaderState) !void {
        const chapters = self.chapters orelse return;
        const allocator = self.allocator;
        const io = self.io;

        var parsed: std.ArrayList(ParsedChapter) = .empty;
        errdefer {
            for (parsed.items) |*p| p.deinit();
            parsed.deinit(allocator);
        }
        try parsed.ensureTotalCapacity(allocator, chapters.items.len);
        for (0..chapters.items.len) |_| {
            try parsed.append(allocator, ParsedChapter.empty(allocator));
        }

        const states = try allocator.alloc(std.atomic.Value(u8), chapters.items.len);
        errdefer allocator.free(states);
        for (states) |*s| s.* = std.atomic.Value(u8).init(chapter_state_unparsed);

        self.parsed_chapters = parsed;
        self.chapter_states = states;

        if (chapters.items.len > 0) {
            states[0].store(chapter_state_parsing, .release);
            const inline_parsed = parseChapterHtml(allocator, chapters.items[0].html_content) catch |err| {
                states[0].store(chapter_state_unparsed, .release);
                return err;
            };
            self.parsed_chapters.?.items[0].deinit();
            self.parsed_chapters.?.items[0] = inline_parsed;
            states[0].store(chapter_state_done, .release);
            self.cache_dirty.store(true, .release);
        }

        for (chapters.items[1..], 1..) |chapter, idx| {
            const slot = &self.parsed_chapters.?.items[idx];
            const slot_state = &states[idx];
            self.parse_group.concurrent(io, parseChapterTask, .{ allocator, chapter.html_content, slot, slot_state, &self.cache_dirty }) catch |err| switch (err) {
                error.ConcurrencyUnavailable => continue,
            };
            self.parse_group_active = true;
        }
    }

    fn ensureChapterParsed(self: *ReaderState, index: usize) void {
        if (index >= self.chapter_states.len) return;
        const slot_state = &self.chapter_states[index];
        const chapters = self.chapters orelse return;

        var observed = slot_state.load(.acquire);
        if (observed == chapter_state_done) return;

        if (observed == chapter_state_unparsed) {
            if (slot_state.cmpxchgStrong(chapter_state_unparsed, chapter_state_parsing, .acq_rel, .acquire) == null) {
                const inline_parsed = parseChapterHtml(self.allocator, chapters.items[index].html_content) catch {
                    slot_state.store(chapter_state_unparsed, .release);
                    return;
                };
                self.parsed_chapters.?.items[index].deinit();
                self.parsed_chapters.?.items[index] = inline_parsed;
                slot_state.store(chapter_state_done, .release);
                self.cache_dirty.store(true, .release);
                return;
            }
        }

        const sleep_ns: i96 = 200_000;
        while (true) {
            observed = slot_state.load(.acquire);
            if (observed == chapter_state_done) return;
            std.Io.sleep(self.io, .fromNanoseconds(sleep_ns), .awake) catch return;
        }
    }

    pub fn loadChapter(self: *ReaderState, index: usize) !void {
        if (self.chapters == null) return;
        const chapters = self.chapters.?;
        if (index >= chapters.items.len) return;

        self.current_chapter = index;
        self.chapter_pages.reset();

        self.ensureChapterParsed(index);

        if (self.parsed_chapters) |pc| {
            if (index < pc.items.len) {
                self.chapter_pages.blocks = pc.items[index].blocks;
            }
        }

        self.chapter_pages.needs_pagination = true;
    }

    pub fn getImageData(self: *ReaderState, filename: []const u8) ?[]const u8 {
        if (self.images) |images| {
            for (images.items) |img| {
                if (std.mem.endsWith(u8, img.filename, filename) or std.mem.eql(u8, img.filename, filename)) {
                    return img.content;
                }
            }
            const base = std.fs.path.basename(filename);
            for (images.items) |img| {
                if (std.mem.endsWith(u8, img.filename, base)) {
                    return img.content;
                }
            }
        }
        return null;
    }

    pub fn paginate(self: *ReaderState) !void {
        self.chapter_pages.pages.clearRetainingCapacity();

        const layout = self.chapter_pages.layout;
        const column_width = computeColumnWidth(self.window_width, layout);
        const content_height = @max(self.window_height - top_bar_height - 40, 100);

        self.chapter_pages.paginated_width = self.window_width;
        self.chapter_pages.paginated_height = self.window_height;
        self.chapter_pages.paginated_column_width = column_width;

        if (self.chapter_pages.blocks.len == 0) {
            try self.chapter_pages.pages.append(self.allocator, .{ .start = 0, .end = 0 });
            self.chapter_pages.needs_pagination = false;
            return;
        }

        const blocks = self.chapter_pages.blocks;
        var page_start: usize = 0;
        var page_height: f32 = 0;
        var i: usize = 0;
        while (i < blocks.len) {
            const block = blocks[i];
            const h = self.estimateBlockHeight(block, column_width);
            const will_overflow = (page_height + h > content_height) and (i > page_start);

            if (will_overflow) {
                var split = i;
                if (split > page_start + 1 and isHeadingBlock(blocks[split - 1])) {
                    split -= 1;
                }

                try self.chapter_pages.pages.append(self.allocator, .{
                    .start = page_start,
                    .end = split,
                });
                page_start = split;
                page_height = 0;
                var j: usize = split;
                while (j < i) : (j += 1) {
                    page_height += self.estimateBlockHeight(blocks[j], column_width);
                }
                continue;
            }

            page_height += h;
            i += 1;
        }

        if (page_start < blocks.len) {
            try self.chapter_pages.pages.append(self.allocator, .{
                .start = page_start,
                .end = blocks.len,
            });
        }

        if (self.chapter_pages.pages.items.len == 0) {
            try self.chapter_pages.pages.append(self.allocator, .{
                .start = 0,
                .end = self.chapter_pages.blocks.len,
            });
        }

        if (self.chapter_pages.current_page >= self.chapter_pages.pages.items.len) {
            self.chapter_pages.current_page = self.chapter_pages.pages.items.len - 1;
        }

        if (self.chapter_pages.layout == .double and self.chapter_pages.current_page % 2 != 0) {
            self.chapter_pages.current_page -= 1;
        }

        self.chapter_pages.needs_pagination = false;
    }

    pub fn estimateBlockHeight(self: *ReaderState, block: Block, max_width: f32) f32 {
        return switch (block.kind) {
            .separator => 36,
            .image => self.estimateImageHeight(block.content, max_width),
            .text => |style| estimateTextHeight(block.content, style, max_width),
        };
    }

    pub fn estimateImageHeight(self: *ReaderState, filename: []const u8, max_width: f32) f32 {
        const data = self.getImageData(filename) orelse return 80;
        const source = dvui.Texture.ImageSource{
            .imageFile = .{ .bytes = data, .name = filename },
        };
        const natural = dvui.imageSize(source) catch return 220;
        const display = computeImageDisplaySize(natural, max_width, image_max_height);
        return display.h + image_vertical_margin * 2;
    }

    pub fn spreadSize(self: *ReaderState) usize {
        return switch (self.chapter_pages.layout) {
            .single => 1,
            .double => 2,
        };
    }

    pub fn nextPage(self: *ReaderState) void {
        const step = self.spreadSize();
        if (self.chapter_pages.current_page + step < self.chapter_pages.pages.items.len) {
            self.chapter_pages.current_page += step;
        } else {
            if (self.chapters) |chapters| {
                if (self.current_chapter + 1 < chapters.items.len) {
                    self.loadChapter(self.current_chapter + 1) catch {};
                }
            }
        }
    }

    pub fn prevPage(self: *ReaderState) void {
        const step = self.spreadSize();
        if (self.chapter_pages.current_page >= step) {
            self.chapter_pages.current_page -= step;
        } else {
            if (self.current_chapter > 0) {
                const new_idx = self.current_chapter - 1;
                self.loadChapter(new_idx) catch {};
                self.chapter_pages.goto_last_page = true;
            }
        }
    }
};

fn estimateTextHeight(text: []const u8, style: TextStyle, max_width: f32) f32 {
    const font = fontForStyle(style);
    const padding = paddingForStyle(style);
    const inner_w = @max(max_width - padding.x - padding.w - 12, 50);

    var lines: f32 = 0;
    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) {
            lines += 1;
            continue;
        }
        var pos: usize = 0;
        while (pos < line.len) {
            var end_idx: usize = 0;
            _ = font.textSizeEx(line[pos..], .{
                .max_width = inner_w,
                .end_idx = &end_idx,
                .end_metric = .before,
            });
            if (end_idx == 0) end_idx = 1;
            lines += 1;
            pos += end_idx;
            if (pos > line.len) pos = line.len;
        }
    }
    if (lines < 1) lines = 1;

    const line_h = font.lineHeight();
    return lines * line_h + padding.y + padding.h;
}
