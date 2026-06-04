const std = @import("std");
const block_mod = @import("block.zig");

const Block = block_mod.Block;
const TextStyle = block_mod.TextStyle;

pub const magic: [4]u8 = .{ 'P', 'U', 'B', 'X' };
pub const version: u32 = 2;

pub const Header = extern struct {
    magic: [4]u8,
    version: u32,
    epub_mtime_ns: i128 align(8),
    chapter_count: u32,
    image_count: u32,
    chapter_index_offset: u64,
    image_index_offset: u64,
    chapter_payloads_offset: u64,
    image_payloads_offset: u64,
    string_pool_offset: u64,
    string_pool_length: u64,
};

pub const ChapterIndexEntry = extern struct {
    payload_offset: u64,
    payload_length: u64,
    title_string_offset: u32,
    title_string_length: u32,
};

pub const ImageIndexEntry = extern struct {
    content_offset: u64,
    content_length: u64,
    filename_string_offset: u32,
    filename_string_length: u32,
};

pub const ChapterHeader = extern struct {
    block_count: u32,
    content_total_bytes: u32,
};

pub const BlockDescriptor = extern struct {
    kind: u8,
    text_style: u8,
    reserved: u16,
    content_offset: u32,
    content_length: u32,
};

pub const block_kind_text: u8 = 0;
pub const block_kind_image: u8 = 1;
pub const block_kind_separator: u8 = 2;

pub fn cachePath(allocator: std.mem.Allocator, environ: *std.process.Environ.Map, epub_path: []const u8) ![]u8 {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(epub_path);
    const h = hasher.final();
    if (environ.get("XDG_DATA_HOME")) |xdg| {
        if (xdg.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/pubix/parsed/{x:0>16}.bin", .{ xdg, h });
        }
    }
    if (environ.get("HOME")) |home| {
        if (home.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/.local/share/pubix/parsed/{x:0>16}.bin", .{ home, h });
        }
    }
    return error.NoHomeDir;
}

fn descriptorForBlock(b: Block) BlockDescriptor {
    switch (b.kind) {
        .text => |style| return .{
            .kind = block_kind_text,
            .text_style = @intFromEnum(style),
            .reserved = 0,
            .content_offset = 0,
            .content_length = 0,
        },
        .image => return .{
            .kind = block_kind_image,
            .text_style = 0,
            .reserved = 0,
            .content_offset = 0,
            .content_length = 0,
        },
        .separator => return .{
            .kind = block_kind_separator,
            .text_style = 0,
            .reserved = 0,
            .content_offset = 0,
            .content_length = 0,
        },
    }
}

pub const ImageRef = struct {
    filename: []const u8,
    content: []const u8,
};

pub fn writeCache(
    io: std.Io,
    cache_path: []const u8,
    epub_mtime_ns: i128,
    chapter_blocks: []const []const Block,
    chapter_titles: []const []const u8,
    images: []const ImageRef,
) !void {
    const chapter_count = chapter_blocks.len;
    const image_count = images.len;

    var string_pool: std.ArrayList(u8) = .empty;
    defer string_pool.deinit(std.heap.page_allocator);

    var chapter_title_offsets: std.ArrayList(u32) = .empty;
    defer chapter_title_offsets.deinit(std.heap.page_allocator);
    var image_filename_offsets: std.ArrayList(u32) = .empty;
    defer image_filename_offsets.deinit(std.heap.page_allocator);

    for (chapter_titles) |title| {
        try chapter_title_offsets.append(std.heap.page_allocator, @intCast(string_pool.items.len));
        try string_pool.appendSlice(std.heap.page_allocator, title);
    }
    for (images) |img| {
        try image_filename_offsets.append(std.heap.page_allocator, @intCast(string_pool.items.len));
        try string_pool.appendSlice(std.heap.page_allocator, img.filename);
    }

    var per_chapter_size: [4096]u64 = undefined;
    if (chapter_count > per_chapter_size.len) return error.TooManyChapters;
    for (chapter_blocks, 0..) |blocks, ch_idx| {
        var content_total: u64 = 0;
        for (blocks) |b| content_total += b.content.len;
        per_chapter_size[ch_idx] = @sizeOf(ChapterHeader) + blocks.len * @sizeOf(BlockDescriptor) + content_total;
    }

    const chapter_index_offset: u64 = @sizeOf(Header);
    const image_index_offset: u64 = chapter_index_offset + chapter_count * @sizeOf(ChapterIndexEntry);
    const string_pool_offset: u64 = image_index_offset + image_count * @sizeOf(ImageIndexEntry);
    const chapter_payloads_offset: u64 = string_pool_offset + string_pool.items.len;

    var chapter_payload_offsets: [4096]u64 = undefined;
    var running: u64 = chapter_payloads_offset;
    for (0..chapter_count) |ch_idx| {
        chapter_payload_offsets[ch_idx] = running;
        running += per_chapter_size[ch_idx];
    }
    const image_payloads_offset: u64 = running;

    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, cache_path, .{ .replace = true, .make_path = true });
    defer atomic.deinit(io);

    var write_buf: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &write_buf);

    var header = Header{
        .magic = magic,
        .version = version,
        .epub_mtime_ns = epub_mtime_ns,
        .chapter_count = @intCast(chapter_count),
        .image_count = @intCast(image_count),
        .chapter_index_offset = chapter_index_offset,
        .image_index_offset = image_index_offset,
        .chapter_payloads_offset = chapter_payloads_offset,
        .image_payloads_offset = image_payloads_offset,
        .string_pool_offset = string_pool_offset,
        .string_pool_length = string_pool.items.len,
    };
    try writeStruct(&writer.interface, &header);

    for (0..chapter_count) |ch_idx| {
        var entry = ChapterIndexEntry{
            .payload_offset = chapter_payload_offsets[ch_idx],
            .payload_length = per_chapter_size[ch_idx],
            .title_string_offset = chapter_title_offsets.items[ch_idx],
            .title_string_length = @intCast(chapter_titles[ch_idx].len),
        };
        try writeStruct(&writer.interface, &entry);
    }

    var img_running: u64 = image_payloads_offset;
    for (images, 0..) |img, i| {
        var entry = ImageIndexEntry{
            .content_offset = img_running,
            .content_length = img.content.len,
            .filename_string_offset = image_filename_offsets.items[i],
            .filename_string_length = @intCast(img.filename.len),
        };
        try writeStruct(&writer.interface, &entry);
        img_running += img.content.len;
    }

    writer.interface.writeAll(string_pool.items) catch |err| switch (err) {
        error.WriteFailed => return writer.err.?,
    };

    for (chapter_blocks) |blocks| {
        var content_total: u32 = 0;
        for (blocks) |b| content_total += @intCast(b.content.len);
        var ch_header = ChapterHeader{
            .block_count = @intCast(blocks.len),
            .content_total_bytes = content_total,
        };
        try writeStruct(&writer.interface, &ch_header);

        var content_cursor: u32 = 0;
        for (blocks) |b| {
            var desc = descriptorForBlock(b);
            desc.content_offset = content_cursor;
            desc.content_length = @intCast(b.content.len);
            try writeStruct(&writer.interface, &desc);
            content_cursor += @intCast(b.content.len);
        }

        for (blocks) |b| {
            writer.interface.writeAll(b.content) catch |err| switch (err) {
                error.WriteFailed => return writer.err.?,
            };
        }
    }

    for (images) |img| {
        writer.interface.writeAll(img.content) catch |err| switch (err) {
            error.WriteFailed => return writer.err.?,
        };
    }

    writer.interface.flush() catch |err| switch (err) {
        error.WriteFailed => return writer.err.?,
    };

    try atomic.replace(io);
}

fn writeStruct(w: *std.Io.Writer, value: anytype) !void {
    const bytes = std.mem.asBytes(value);
    w.writeAll(bytes) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
    };
}

pub const CacheView = struct {
    file: std.Io.File,
    mm: std.Io.File.MemoryMap,
    bytes: []const u8,
    header: *align(1) const Header,
    chapter_index: []align(1) const ChapterIndexEntry,
    image_index: []align(1) const ImageIndexEntry,
    string_pool: []const u8,

    pub fn deinit(self: *CacheView, io: std.Io) void {
        self.mm.destroy(io);
        self.file.close(io);
    }

    pub fn chapterCount(self: CacheView) usize {
        return self.header.chapter_count;
    }

    pub fn imageCount(self: CacheView) usize {
        return self.header.image_count;
    }

    pub fn chapterPayload(self: CacheView, index: usize) ?[]const u8 {
        if (index >= self.chapter_index.len) return null;
        const entry = self.chapter_index[index];
        const start: usize = @intCast(entry.payload_offset);
        const end: usize = @intCast(entry.payload_offset + entry.payload_length);
        if (end > self.bytes.len) return null;
        return self.bytes[start..end];
    }

    pub fn chapterTitle(self: CacheView, index: usize) ?[]const u8 {
        if (index >= self.chapter_index.len) return null;
        const entry = self.chapter_index[index];
        const start: usize = entry.title_string_offset;
        const end: usize = start + entry.title_string_length;
        if (end > self.string_pool.len) return null;
        return self.string_pool[start..end];
    }

    pub fn imageRef(self: CacheView, index: usize) ?ImageRef {
        if (index >= self.image_index.len) return null;
        const entry = self.image_index[index];
        const fn_start: usize = entry.filename_string_offset;
        const fn_end: usize = fn_start + entry.filename_string_length;
        if (fn_end > self.string_pool.len) return null;
        const content_start: usize = @intCast(entry.content_offset);
        const content_end: usize = @intCast(entry.content_offset + entry.content_length);
        if (content_end > self.bytes.len) return null;
        return .{
            .filename = self.string_pool[fn_start..fn_end],
            .content = self.bytes[content_start..content_end],
        };
    }
};

pub fn openCache(io: std.Io, cache_path: []const u8, expected_epub_mtime_ns: i128) !?CacheView {
    const file = std.Io.Dir.cwd().openFile(io, cache_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    errdefer file.close(io);

    const stat = try file.stat(io);
    if (stat.size < @sizeOf(Header)) {
        file.close(io);
        return null;
    }

    var mm = std.Io.File.MemoryMap.create(io, file, .{
        .len = @intCast(stat.size),
        .protection = .{ .read = true, .write = false },
        .offset = 0,
    }) catch {
        file.close(io);
        return null;
    };
    errdefer mm.destroy(io);

    const bytes = mm.memory[0..@intCast(stat.size)];
    const header: *align(1) const Header = @ptrCast(bytes.ptr);

    if (!std.mem.eql(u8, &header.magic, &magic)) {
        mm.destroy(io);
        file.close(io);
        return null;
    }
    if (header.version != version) {
        mm.destroy(io);
        file.close(io);
        return null;
    }
    if (header.epub_mtime_ns != expected_epub_mtime_ns) {
        mm.destroy(io);
        file.close(io);
        return null;
    }

    const chapter_count = header.chapter_count;
    const image_count = header.image_count;

    const chapter_index_start: usize = @intCast(header.chapter_index_offset);
    const chapter_index_end: usize = chapter_index_start + chapter_count * @sizeOf(ChapterIndexEntry);
    if (chapter_index_end > bytes.len) {
        mm.destroy(io);
        file.close(io);
        return null;
    }
    const chapter_index_ptr: [*]align(1) const ChapterIndexEntry = @ptrCast(bytes.ptr + chapter_index_start);
    const chapter_index = chapter_index_ptr[0..chapter_count];

    const image_index_start: usize = @intCast(header.image_index_offset);
    const image_index_end: usize = image_index_start + image_count * @sizeOf(ImageIndexEntry);
    if (image_index_end > bytes.len) {
        mm.destroy(io);
        file.close(io);
        return null;
    }
    const image_index_ptr: [*]align(1) const ImageIndexEntry = @ptrCast(bytes.ptr + image_index_start);
    const image_index = image_index_ptr[0..image_count];

    const string_pool_start: usize = @intCast(header.string_pool_offset);
    const string_pool_end: usize = string_pool_start + @as(usize, @intCast(header.string_pool_length));
    if (string_pool_end > bytes.len) {
        mm.destroy(io);
        file.close(io);
        return null;
    }
    const string_pool = bytes[string_pool_start..string_pool_end];

    return .{
        .file = file,
        .mm = mm,
        .bytes = bytes,
        .header = header,
        .chapter_index = chapter_index,
        .image_index = image_index,
        .string_pool = string_pool,
    };
}

pub fn decodeChapter(
    payload: []const u8,
    arena_alloc: std.mem.Allocator,
) ![]const Block {
    if (payload.len < @sizeOf(ChapterHeader)) return error.CacheCorrupt;
    const ch_header: *align(1) const ChapterHeader = @ptrCast(payload.ptr);
    const block_count = ch_header.block_count;

    const descriptors_start: usize = @sizeOf(ChapterHeader);
    const descriptors_end: usize = descriptors_start + @as(usize, block_count) * @sizeOf(BlockDescriptor);
    if (descriptors_end > payload.len) return error.CacheCorrupt;

    const descriptors_ptr: [*]align(1) const BlockDescriptor = @ptrCast(payload.ptr + descriptors_start);
    const descriptors = descriptors_ptr[0..block_count];

    const content_start: usize = descriptors_end;
    const content_total: usize = ch_header.content_total_bytes;
    if (content_start + content_total > payload.len) return error.CacheCorrupt;
    const content_bytes = payload[content_start .. content_start + content_total];

    const blocks = try arena_alloc.alloc(Block, block_count);
    for (descriptors, 0..) |desc, i| {
        const offset: usize = desc.content_offset;
        const length: usize = desc.content_length;
        if (offset + length > content_bytes.len) return error.CacheCorrupt;
        const slice = content_bytes[offset .. offset + length];
        const kind: block_mod.BlockKind = switch (desc.kind) {
            block_kind_text => .{ .text = @enumFromInt(desc.text_style) },
            block_kind_image => .image,
            block_kind_separator => .separator,
            else => return error.CacheCorrupt,
        };
        blocks[i] = .{ .kind = kind, .content = slice };
    }
    return blocks;
}
