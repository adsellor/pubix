const std = @import("std");

pub const BookEntry = struct {
    path: []const u8,
    title: []const u8,
    author: ?[]const u8,
    chapter_count: usize,
    last_chapter: usize = 0,
    last_page: usize = 0,
    last_opened: i64 = 0,
    cover_path: ?[]const u8 = null,
    cover_bytes: ?[]const u8 = null,

    pub fn deinit(self: *BookEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.title);
        if (self.author) |a| allocator.free(a);
        if (self.cover_path) |c| allocator.free(c);
        if (self.cover_bytes) |b| allocator.free(b);
    }
};

pub const Library = struct {
    allocator: std.mem.Allocator,
    books: std.ArrayList(BookEntry),
    storage_path: []const u8,
    covers_dir: []const u8,
    sorted_indices_buf: [256]usize = undefined,
    sorted_indices_len: usize = 0,
    sorted_indices_dirty: bool = true,
    sorted_indices_overflow: []usize = &.{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map) !Library {
        const storage_path = try resolveStoragePath(allocator, environ);
        errdefer allocator.free(storage_path);

        const covers_dir = try resolveCoversDir(allocator, storage_path);
        errdefer allocator.free(covers_dir);

        try ensureParentDir(io, storage_path);
        std.Io.Dir.cwd().createDirPath(io, covers_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => std.log.warn("library: covers dir create failed: {t}", .{err}),
        };

        var lib: Library = .{
            .allocator = allocator,
            .books = .empty,
            .storage_path = storage_path,
            .covers_dir = covers_dir,
            .sorted_indices_buf = undefined,
            .sorted_indices_len = 0,
            .sorted_indices_dirty = true,
            .sorted_indices_overflow = &.{},
        };
        lib.load(io) catch |err| switch (err) {
            error.FileNotFound => {},
            else => std.log.warn("library: load failed: {t} (starting empty)", .{err}),
        };
        lib.loadAllCoverBytes(io);
        return lib;
    }

    pub fn deinit(self: *Library) void {
        for (self.books.items) |*b| b.deinit(self.allocator);
        self.books.deinit(self.allocator);
        self.allocator.free(self.storage_path);
        self.allocator.free(self.covers_dir);
        if (self.sorted_indices_overflow.len > 0) {
            self.allocator.free(self.sorted_indices_overflow);
            self.sorted_indices_overflow = &.{};
        }
    }

    pub fn load(self: *Library, io: std.Io) !void {
        const file = try std.Io.Dir.cwd().openFile(io, self.storage_path, .{});
        defer file.close(io);

        var read_buf: [4096]u8 = undefined;
        var reader = std.Io.File.Reader.init(file, io, &read_buf);

        const raw = reader.interface.allocRemaining(self.allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            else => return err,
        };
        defer self.allocator.free(raw);

        const parsed = std.json.parseFromSlice(JsonShape, self.allocator, raw, .{ .ignore_unknown_fields = true }) catch {
            return error.InvalidJson;
        };
        defer parsed.deinit();

        for (parsed.value.books) |jb| {
            const path_copy = try self.allocator.dupe(u8, jb.path);
            errdefer self.allocator.free(path_copy);
            const title_copy = try self.allocator.dupe(u8, jb.title);
            errdefer self.allocator.free(title_copy);
            const author_copy: ?[]const u8 = if (jb.author) |a| try self.allocator.dupe(u8, a) else null;
            errdefer if (author_copy) |a| self.allocator.free(a);
            const cover_path_copy: ?[]const u8 = if (jb.cover_path) |c| try self.allocator.dupe(u8, c) else null;
            errdefer if (cover_path_copy) |c| self.allocator.free(c);

            try self.books.append(self.allocator, .{
                .path = path_copy,
                .title = title_copy,
                .author = author_copy,
                .chapter_count = jb.chapter_count,
                .last_chapter = jb.last_chapter,
                .last_page = jb.last_page,
                .last_opened = jb.last_opened,
                .cover_path = cover_path_copy,
            });
        }
        self.sorted_indices_dirty = true;
    }

    fn loadAllCoverBytes(self: *Library, io: std.Io) void {
        for (self.books.items) |*book| {
            const cover_path = book.cover_path orelse continue;
            const bytes = readFileBytes(self.allocator, io, cover_path) catch |err| {
                std.log.warn("library: failed to read cover '{s}': {t}", .{ cover_path, err });
                continue;
            };
            book.cover_bytes = bytes;
        }
    }

    pub fn attachCover(self: *Library, io: std.Io, idx: usize, bytes: []const u8) !void {
        if (idx >= self.books.items.len) return;
        const book = &self.books.items[idx];
        const filename = try coverFilename(self.allocator, book.path);
        defer self.allocator.free(filename);

        const dest = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.covers_dir, filename });
        errdefer self.allocator.free(dest);

        try writeFileBytes(io, dest, bytes);

        if (book.cover_path) |old| self.allocator.free(old);
        book.cover_path = dest;

        if (book.cover_bytes) |old| self.allocator.free(old);
        book.cover_bytes = try self.allocator.dupe(u8, bytes);
    }

    pub fn save(self: *Library, io: std.Io) !void {
        var json_books: std.ArrayList(JsonBook) = .empty;
        defer json_books.deinit(self.allocator);
        try json_books.ensureTotalCapacity(self.allocator, self.books.items.len);
        for (self.books.items) |b| {
            try json_books.append(self.allocator, .{
                .path = b.path,
                .title = b.title,
                .author = b.author,
                .chapter_count = b.chapter_count,
                .last_chapter = b.last_chapter,
                .last_page = b.last_page,
                .last_opened = b.last_opened,
                .cover_path = b.cover_path,
            });
        }
        const shape: JsonShape = .{
            .version = 1,
            .books = json_books.items,
        };

        const json_text = try std.fmt.allocPrint(self.allocator, "{f}\n", .{std.json.fmt(shape, .{ .whitespace = .indent_2 })});
        defer self.allocator.free(json_text);

        var atomic = try std.Io.Dir.cwd().createFileAtomic(io, self.storage_path, .{ .replace = true });
        defer atomic.deinit(io);

        var write_buf: [4096]u8 = undefined;
        var writer = atomic.file.writer(io, &write_buf);
        writer.interface.writeAll(json_text) catch |err| switch (err) {
            error.WriteFailed => return writer.err.?,
        };
        writer.interface.flush() catch |err| switch (err) {
            error.WriteFailed => return writer.err.?,
        };

        try atomic.replace(io);
    }

    pub fn findByPath(self: *Library, path: []const u8) ?usize {
        for (self.books.items, 0..) |b, i| {
            if (std.mem.eql(u8, b.path, path)) return i;
        }
        return null;
    }

    pub fn addBook(
        self: *Library,
        epub_path: []const u8,
        title: []const u8,
        author: ?[]const u8,
        chapter_count: usize,
    ) !usize {
        if (self.findByPath(epub_path)) |idx| return idx;

        const path_copy = try self.allocator.dupe(u8, epub_path);
        errdefer self.allocator.free(path_copy);
        const title_copy = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(title_copy);
        const author_copy: ?[]const u8 = if (author) |a| try self.allocator.dupe(u8, a) else null;
        errdefer if (author_copy) |a| self.allocator.free(a);

        try self.books.append(self.allocator, .{
            .path = path_copy,
            .title = title_copy,
            .author = author_copy,
            .chapter_count = chapter_count,
        });
        self.sorted_indices_dirty = true;
        return self.books.items.len - 1;
    }

    pub fn updateProgress(self: *Library, idx: usize, chapter: usize, page: usize, now_unix: i64) void {
        if (idx >= self.books.items.len) return;
        const b = &self.books.items[idx];
        b.last_chapter = chapter;
        b.last_page = page;
        b.last_opened = now_unix;
        self.sorted_indices_dirty = true;
    }

    pub fn touchOpenedAt(self: *Library, idx: usize, now_unix: i64) void {
        if (idx >= self.books.items.len) return;
        self.books.items[idx].last_opened = now_unix;
        self.sorted_indices_dirty = true;
    }

    pub fn sortedIndices(self: *Library) []const usize {
        if (!self.sorted_indices_dirty) {
            return self.activeBuffer()[0..self.sorted_indices_len];
        }
        const n = self.books.items.len;
        const dst = if (n <= self.sorted_indices_buf.len)
            self.sorted_indices_buf[0..n]
        else blk: {
            if (self.sorted_indices_overflow.len < n) {
                if (self.sorted_indices_overflow.len > 0) self.allocator.free(self.sorted_indices_overflow);
                self.sorted_indices_overflow = self.allocator.alloc(usize, n) catch {
                    self.sorted_indices_len = 0;
                    self.sorted_indices_dirty = false;
                    return &.{};
                };
            }
            break :blk self.sorted_indices_overflow[0..n];
        };
        for (0..n) |i| dst[i] = i;
        std.mem.sort(usize, dst, self, sortByRecencyDesc);
        self.sorted_indices_len = n;
        self.sorted_indices_dirty = false;
        return dst;
    }

    fn activeBuffer(self: *Library) []usize {
        if (self.sorted_indices_len <= self.sorted_indices_buf.len) {
            return self.sorted_indices_buf[0..self.sorted_indices_buf.len];
        }
        return self.sorted_indices_overflow;
    }
};

fn sortByRecencyDesc(lib: *Library, a: usize, b: usize) bool {
    const ba = lib.books.items[a];
    const bb = lib.books.items[b];
    const a_unopened = ba.last_opened == 0;
    const b_unopened = bb.last_opened == 0;
    if (a_unopened and !b_unopened) return true;
    if (!a_unopened and b_unopened) return false;
    return ba.last_opened > bb.last_opened;
}

const JsonBook = struct {
    path: []const u8,
    title: []const u8,
    author: ?[]const u8 = null,
    chapter_count: usize,
    last_chapter: usize = 0,
    last_page: usize = 0,
    last_opened: i64 = 0,
    cover_path: ?[]const u8 = null,
};

const JsonShape = struct {
    version: u32,
    books: []const JsonBook,
};

fn resolveStoragePath(allocator: std.mem.Allocator, environ: *std.process.Environ.Map) ![]const u8 {
    if (environ.get("XDG_DATA_HOME")) |xdg| {
        if (xdg.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/pubix/library.json", .{xdg});
        }
    }
    if (environ.get("HOME")) |home| {
        if (home.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/.local/share/pubix/library.json", .{home});
        }
    }
    return error.NoHomeDir;
}

fn ensureParentDir(io: std.Io, file_path: []const u8) !void {
    const dir = std.Io.Dir.path.dirname(file_path) orelse return;
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
}

fn resolveCoversDir(allocator: std.mem.Allocator, storage_path: []const u8) ![]const u8 {
    const parent = std.Io.Dir.path.dirname(storage_path) orelse return error.NoHomeDir;
    return std.fmt.allocPrint(allocator, "{s}/covers", .{parent});
}

fn coverFilename(allocator: std.mem.Allocator, epub_path: []const u8) ![]u8 {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(epub_path);
    const h = hasher.final();
    return std.fmt.allocPrint(allocator, "{x:0>16}.bin", .{h});
}

fn readFileBytes(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var reader = std.Io.File.Reader.init(file, io, &buf);

    return reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => return err,
    };
}

fn writeFileBytes(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true, .make_path = true });
    defer atomic.deinit(io);

    var buf: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buf);
    writer.interface.writeAll(bytes) catch |err| switch (err) {
        error.WriteFailed => return writer.err.?,
    };
    writer.interface.flush() catch |err| switch (err) {
        error.WriteFailed => return writer.err.?,
    };

    try atomic.replace(io);
}

pub fn extractCoverFromEpub(allocator: std.mem.Allocator, epub: anytype) !?[]u8 {
    const image_exts: []const []const u8 = &.{ ".jpg", ".jpeg", ".png", ".webp" };

    for (epub.files.items) |file| {
        var matched = false;
        for (image_exts) |ext| {
            if (hasIgnoreCaseSuffix(file.filename, ext)) {
                matched = true;
                break;
            }
        }
        if (!matched) continue;
        if (containsIgnoreCase(file.filename, "cover")) {
            return try allocator.dupe(u8, file.content);
        }
    }

    for (epub.files.items) |file| {
        for (image_exts) |ext| {
            if (hasIgnoreCaseSuffix(file.filename, ext)) {
                return try allocator.dupe(u8, file.content);
            }
        }
    }

    return null;
}

fn hasIgnoreCaseSuffix(name: []const u8, suffix: []const u8) bool {
    if (name.len < suffix.len) return false;
    const tail = name[name.len - suffix.len ..];
    for (tail, suffix) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}
