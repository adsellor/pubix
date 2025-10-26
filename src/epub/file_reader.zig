const std = @import("std");
const builtin = @import("builtin");
const zip = std.zip;
const print = @import("std").debug.print;
const is_le = builtin.target.cpu.arch.endian() == .little;

pub const EpubMetadata = struct {
    title: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    language: ?[]const u8 = null,
    identifier: ?[]const u8 = null,

    pub fn deinit(self: *EpubMetadata, allocator: std.mem.Allocator) void {
        if (self.title) |t| allocator.free(t);
        if (self.creator) |c| allocator.free(c);
        if (self.language) |l| allocator.free(l);
        if (self.identifier) |i| allocator.free(i);
    }
};

pub const ManifestItem = struct {
    id: []const u8,
    href: []const u8,
    media_type: []const u8,

    pub fn deinit(self: *ManifestItem, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.href);
        allocator.free(self.media_type);
    }
};

pub const SpineItem = struct {
    idref: []const u8,

    pub fn deinit(self: *SpineItem, allocator: std.mem.Allocator) void {
        allocator.free(self.idref);
    }
};

pub const ExtractedFile = struct {
    filename: []const u8,
    content: []const u8,

    pub fn deinit(self: *ExtractedFile, allocator: std.mem.Allocator) void {
        allocator.free(self.filename);
        allocator.free(self.content);
    }
};

pub const Chapter = struct {
    title: []const u8,
    html_content: []const u8,
    filename: []const u8,
    chapter_number: usize,

    pub fn deinit(self: *Chapter, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.html_content);
        allocator.free(self.filename);
    }
};

pub const Page = struct {
    content: []const u8,
    page_number: usize,
    chapter_number: usize,
    chapter_title: []const u8,
    start_position: usize,
    end_position: usize,

    pub fn deinit(self: *Page, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        allocator.free(self.chapter_title);
    }
};

pub const Epub = struct {
    allocator: std.mem.Allocator,
    metadata: EpubMetadata,
    manifest: std.ArrayList(ManifestItem),
    spine: std.ArrayList(SpineItem),
    files: std.ArrayList(ExtractedFile),
    pages: std.ArrayList(Page),
    content_opf_path: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) Epub {
        return .{
            .allocator = allocator,
            .metadata = .{},
            .manifest = std.ArrayList(ManifestItem){},
            .spine = std.ArrayList(SpineItem){},
            .files = std.ArrayList(ExtractedFile){},
            .pages = std.ArrayList(Page){},
        };
    }

    pub fn deinit(self: *Epub) void {
        self.metadata.deinit(self.allocator);

        for (self.manifest.items) |*item| {
            item.deinit(self.allocator);
        }
        self.manifest.deinit(self.allocator);

        for (self.spine.items) |*item| {
            item.deinit(self.allocator);
        }
        self.spine.deinit(self.allocator);

        for (self.files.items) |*file| {
            file.deinit(self.allocator);
        }
        self.files.deinit(self.allocator);

        for (self.pages.items) |*page| {
            page.deinit(self.allocator);
        }
        self.pages.deinit(self.allocator);

        if (self.content_opf_path) |path| {
            self.allocator.free(path);
        }
    }

    pub fn getFile(self: *Epub, filename: []const u8) ?[]const u8 {
        for (self.files.items) |file| {
            if (std.mem.eql(u8, file.filename, filename)) {
                return file.content;
            }
        }
        return null;
    }

    pub fn getChapterFiles(self: *Epub) !std.ArrayList(ExtractedFile) {
        var chapters = std.ArrayList(ExtractedFile){};

        for (self.files.items) |file| {
            if (std.mem.endsWith(u8, file.filename, ".html") or
                std.mem.endsWith(u8, file.filename, ".xhtml"))
            {
                if (std.mem.indexOf(u8, file.filename, "toc") != null or
                    std.mem.indexOf(u8, file.filename, "cover") != null or
                    std.mem.indexOf(u8, file.filename, "titlepage") != null or
                    std.mem.indexOf(u8, file.filename, "copyright") != null or
                    std.mem.indexOf(u8, file.filename, "dedication") != null or
                    std.mem.indexOf(u8, file.filename, "preface") != null or
                    std.mem.indexOf(u8, file.filename, "colophon") != null)
                {
                    continue;
                }
                try chapters.append(self.allocator, file);
            }
        }

        return chapters;
    }

    pub fn getImages(self: *Epub) !std.ArrayList(ExtractedFile) {
        var images = std.ArrayList(ExtractedFile){};

        for (self.files.items) |file| {
            if (std.mem.endsWith(u8, file.filename, ".png") or
                std.mem.endsWith(u8, file.filename, ".jpg") or
                std.mem.endsWith(u8, file.filename, ".jpeg") or
                std.mem.endsWith(u8, file.filename, ".gif") or
                std.mem.endsWith(u8, file.filename, ".svg"))
            {
                try images.append(self.allocator, file);
            }
        }

        return images;
    }

    pub fn getOrderedChapters(self: *Epub) !std.ArrayList(ExtractedFile) {
        var chapters = std.ArrayList(ExtractedFile){};

        for (self.spine.items) |spine_item| {
            for (self.manifest.items) |manifest_item| {
                if (std.mem.eql(u8, spine_item.idref, manifest_item.id)) {
                    for (self.files.items) |file| {
                        if (std.mem.endsWith(u8, file.filename, manifest_item.href) or
                            std.mem.eql(u8, file.filename, manifest_item.href))
                        {
                            try chapters.append(self.allocator, file);
                            break;
                        }
                    }
                    break;
                }
            }
        }

        return chapters;
    }

    pub fn getTocContent(self: *Epub) ?[]const u8 {
        for (self.files.items) |file| {
            if (std.mem.indexOf(u8, file.filename, "toc") != null and
                (std.mem.endsWith(u8, file.filename, ".html") or
                    std.mem.endsWith(u8, file.filename, ".xhtml") or
                    std.mem.endsWith(u8, file.filename, ".ncx")))
            {
                return file.content;
            }
        }
        return null;
    }

    pub fn getCoverContent(self: *Epub) ?[]const u8 {
        for (self.files.items) |file| {
            if (std.mem.indexOf(u8, file.filename, "cover") != null) {
                return file.content;
            }
        }
        return null;
    }

    pub fn getAllFiles(self: *Epub) []ExtractedFile {
        return self.files.items;
    }

    pub fn getChapters(self: *Epub) !std.ArrayList(Chapter) {
        var chapters = std.ArrayList(Chapter){};

        var ordered_files = try self.getOrderedChapters();
        defer ordered_files.deinit(self.allocator);

        for (ordered_files.items, 0..) |file, i| {
            // Skip non-content files (cover, toc, etc.)
            if (self.isContentChapter(file.filename)) {
                const title = try self.extractChapterTitle(file.content, file.filename);
                const html_copy = try self.allocator.dupe(u8, file.content);
                const filename_copy = try self.allocator.dupe(u8, file.filename);

                try chapters.append(self.allocator, .{
                    .title = title,
                    .html_content = html_copy,
                    .filename = filename_copy,
                    .chapter_number = i + 1,
                });
            }
        }

        return chapters;
    }

    pub fn getChapter(self: *Epub, index: usize) !?Chapter {
        var chapters = try self.getChapters();
        defer {
            for (chapters.items) |*chapter| {
                chapter.deinit(self.allocator);
            }
            chapters.deinit(self.allocator);
        }

        if (index >= chapters.items.len) return null;

        const chapter = chapters.items[index];
        return .{
            .title = try self.allocator.dupe(u8, chapter.title),
            .html_content = try self.allocator.dupe(u8, chapter.html_content),
            .filename = try self.allocator.dupe(u8, chapter.filename),
            .chapter_number = chapter.chapter_number,
        };
    }

    pub fn getChapterByFilename(self: *Epub, filename: []const u8) !?Chapter {
        var chapters = try self.getChapters();
        defer {
            for (chapters.items) |*chapter| {
                chapter.deinit(self.allocator);
            }
            chapters.deinit(self.allocator);
        }

        for (chapters.items) |chapter| {
            if (std.mem.eql(u8, chapter.filename, filename)) {
                return .{
                    .title = try self.allocator.dupe(u8, chapter.title),
                    .html_content = try self.allocator.dupe(u8, chapter.html_content),
                    .filename = try self.allocator.dupe(u8, chapter.filename),
                    .chapter_number = chapter.chapter_number,
                };
            }
        }

        return null;
    }

    pub fn getPages(self: *Epub, words_per_page: usize) !std.ArrayList(Page) {
        var pages = std.ArrayList(Page){};

        var chapters = try self.getChapters();
        defer {
            for (chapters.items) |*chapter| {
                chapter.deinit(self.allocator);
            }
            chapters.deinit(self.allocator);
        }

        var current_page_number: usize = 1;

        for (chapters.items) |chapter| {
            const text_content = try self.extractTextFromHtml(chapter.html_content);
            defer self.allocator.free(text_content);

            const words = try self.splitIntoWords(text_content);
            defer {
                for (words.items) |word| {
                    self.allocator.free(word);
                }
                words.deinit(self.allocator);
            }

            var word_index: usize = 0;
            while (word_index < words.items.len) {
                const end_index = @min(word_index + words_per_page, words.items.len);
                const page_words = words.items[word_index..end_index];

                const page_content = try self.joinWords(page_words);
                const chapter_title_copy = try self.allocator.dupe(u8, chapter.title);

                try pages.append(self.allocator, .{
                    .content = page_content,
                    .page_number = current_page_number,
                    .chapter_number = chapter.chapter_number,
                    .chapter_title = chapter_title_copy,
                    .start_position = word_index,
                    .end_position = end_index,
                });

                current_page_number += 1;
                word_index = end_index;
            }
        }

        return pages;
    }

    pub fn getPage(self: *Epub, page_number: usize, words_per_page: usize) !?Page {
        if (self.pages.items.len == 0) {
            self.pages = try self.getPages(words_per_page);
        }

        if (page_number == 0 or page_number > self.pages.items.len) {
            return null;
        }

        const page = self.pages.items[page_number - 1];
        return .{
            .content = try self.allocator.dupe(u8, page.content),
            .page_number = page.page_number,
            .chapter_number = page.chapter_number,
            .chapter_title = try self.allocator.dupe(u8, page.chapter_title),
            .start_position = page.start_position,
            .end_position = page.end_position,
        };
    }

    pub fn getTotalPages(self: *Epub, words_per_page: usize) !usize {
        if (self.pages.items.len == 0) {
            self.pages = try self.getPages(words_per_page);
        }
        return self.pages.items.len;
    }

    fn extractTextFromHtml(self: *Epub, html: []const u8) ![]u8 {
        var result = std.ArrayList(u8){};
        var i: usize = 0;
        var in_tag = false;

        while (i < html.len) {
            if (html[i] == '<') {
                in_tag = true;
            } else if (html[i] == '>') {
                in_tag = false;
                if (i + 1 < html.len) {
                    try result.append(self.allocator, ' ');
                }
            } else if (!in_tag) {
                if (html[i] == '&') {
                    const entity_end = std.mem.indexOfScalarPos(u8, html, i, ';');
                    if (entity_end) |end| {
                        const entity = html[i .. end + 1];
                        if (std.mem.eql(u8, entity, "&amp;")) {
                            try result.append(self.allocator, '&');
                        } else if (std.mem.eql(u8, entity, "&lt;")) {
                            try result.append(self.allocator, '<');
                        } else if (std.mem.eql(u8, entity, "&gt;")) {
                            try result.append(self.allocator, '>');
                        } else if (std.mem.eql(u8, entity, "&quot;")) {
                            try result.append(self.allocator, '"');
                        } else if (std.mem.eql(u8, entity, "&apos;")) {
                            try result.append(self.allocator, '\'');
                        } else if (std.mem.eql(u8, entity, "&nbsp;")) {
                            try result.append(self.allocator, ' ');
                        } else {
                            try result.append(self.allocator, ' ');
                        }
                        i = end;
                    } else {
                        try result.append(self.allocator, html[i]);
                    }
                } else {
                    try result.append(self.allocator, html[i]);
                }
            }
            i += 1;
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn splitIntoWords(self: *Epub, text: []const u8) !std.ArrayList([]u8) {
        var words = std.ArrayList([]u8){};
        var word_start: ?usize = null;

        for (text, 0..) |char, i| {
            if (std.ascii.isAlphanumeric(char) or char == '\'' or char == '-') {
                if (word_start == null) {
                    word_start = i;
                }
            } else {
                if (word_start) |start| {
                    const word = try self.allocator.dupe(u8, text[start..i]);
                    try words.append(self.allocator, word);
                    word_start = null;
                }
            }
        }

        if (word_start) |start| {
            const word = try self.allocator.dupe(u8, text[start..]);
            try words.append(self.allocator, word);
        }

        return words;
    }

    fn joinWords(self: *Epub, words: [][]const u8) ![]u8 {
        if (words.len == 0) return try self.allocator.alloc(u8, 0);

        var total_len: usize = 0;
        for (words) |word| {
            total_len += word.len + 1;
        }

        var result = try self.allocator.alloc(u8, total_len);
        var pos: usize = 0;

        for (words, 0..) |word, i| {
            @memcpy(result[pos .. pos + word.len], word);
            pos += word.len;
            if (i < words.len - 1) {
                result[pos] = ' ';
                pos += 1;
            }
        }

        return result[0..pos];
    }

    fn isContentChapter(self: *Epub, filename: []const u8) bool {
        const lower_filename = std.ascii.allocLowerString(self.allocator, filename) catch return false;
        defer self.allocator.free(lower_filename);

        const skip_patterns = [_][]const u8{ "cover", "toc", "titlepage", "copyright", "dedication", "preface", "colophon", "glossary", "index", "part" };

        for (skip_patterns) |pattern| {
            if (std.mem.indexOf(u8, lower_filename, pattern) != null) {
                return false;
            }
        }

        if (std.mem.endsWith(u8, lower_filename, ".html") or
            std.mem.endsWith(u8, lower_filename, ".xhtml"))
        {
            return std.mem.indexOf(u8, lower_filename, "ch") != null or
                std.mem.indexOf(u8, lower_filename, "chapter") != null;
        }

        return false;
    }

    fn extractChapterTitle(self: *Epub, html_content: []const u8, filename: []const u8) ![]const u8 {
        if (self.extractHtmlTitle(html_content)) |title| {
            return try self.allocator.dupe(u8, title);
        }

        if (self.extractFirstHeading(html_content)) |heading| {
            return try self.allocator.dupe(u8, heading);
        }

        return self.generateTitleFromFilename(filename);
    }

    fn extractHtmlTitle(self: *Epub, html: []const u8) ?[]const u8 {
        _ = self;
        const start_tag = "<title>";
        const end_tag = "</title>";

        const start_pos = std.mem.indexOf(u8, html, start_tag) orelse return null;
        const title_start = start_pos + start_tag.len;
        const title_end = std.mem.indexOfPos(u8, html, title_start, end_tag) orelse return null;

        const title = html[title_start..title_end];

        return std.mem.trim(u8, title, " \t\n\r");
    }

    fn extractFirstHeading(self: *Epub, html: []const u8) ?[]const u8 {
        _ = self;
        const start_tag = "<h1";
        const end_tag = "</h1>";

        const start_pos = std.mem.indexOf(u8, html, start_tag) orelse return null;
        const content_start = std.mem.indexOfScalarPos(u8, html, start_pos, '>') orelse return null;
        const heading_start = content_start + 1;
        const heading_end = std.mem.indexOfPos(u8, html, heading_start, end_tag) orelse return null;

        const heading = html[heading_start..heading_end];
        return std.mem.trim(u8, heading, " \t\n\r");
    }

    fn generateTitleFromFilename(self: *Epub, filename: []const u8) ![]const u8 {
        const basename = std.fs.path.basename(filename);
        const name_without_ext = if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot_pos|
            basename[0..dot_pos]
        else
            basename;

        if (std.mem.startsWith(u8, name_without_ext, "ch")) {
            const chapter_num = name_without_ext[2..];
            return try std.fmt.allocPrint(self.allocator, "Chapter {s}", .{chapter_num});
        }

        var title = try self.allocator.dupe(u8, name_without_ext);
        if (title.len > 0) {
            title[0] = std.ascii.toUpper(title[0]);
        }
        return title;
    }
};

pub const EpubParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EpubParser {
        return .{ .allocator = allocator };
    }

    pub fn parseEpub(self: *EpubParser, filepath: []const u8) !Epub {
        const extracted_files = try self.extractEpub(filepath);

        var epub = Epub.init(self.allocator);
        epub.files = extracted_files;

        for (epub.files.items) |file| {
            if (std.mem.eql(u8, file.filename, "META-INF/container.xml")) {
                const opf_path = parseContainerXml(file.content) catch {
                    std.debug.print("Warning: Could not parse container.xml\n", .{});
                    return epub;
                };
                epub.content_opf_path = try self.allocator.dupe(u8, opf_path);
                break;
            }
        }

        if (epub.content_opf_path) |opf_path| {
            for (epub.files.items) |file| {
                if (std.mem.eql(u8, file.filename, opf_path)) {
                    self.parseContentOpf(file.content, &epub) catch {
                        std.debug.print("Warning: Could not parse content.opf\n", .{});
                    };
                    break;
                }
            }
        }

        return epub;
    }

    pub fn extractEpub(self: *EpubParser, filepath: []const u8) !std.ArrayList(ExtractedFile) {
        var file = try std.fs.cwd().openFile(filepath, .{});
        defer file.close();

        var file_buffer: [8192]u8 = undefined;
        var file_reader = file.reader(&file_buffer);
        var iter = try zip.Iterator.init(&file_reader);

        var extracted_files = std.ArrayList(ExtractedFile){};
        var filename_buf: [std.fs.max_path_bytes]u8 = undefined;

        while (try iter.next()) |entry| {
            if (entry.filename_len > filename_buf.len) {
                std.debug.print("  Warning: filename too long ({d} bytes), skipping\n", .{entry.filename_len});
                continue;
            }

            const filename = filename_buf[0..entry.filename_len];
            try file.seekTo(entry.header_zip_offset + @sizeOf(zip.CentralDirectoryFileHeader));
            _ = try file.readAll(filename);

            if (filename[filename.len - 1] == '/') {
                continue;
            }

            const content = try self.extractEntryContent(&file, entry);
            const filename_copy = try self.allocator.dupe(u8, filename);

            try extracted_files.append(self.allocator, .{
                .filename = filename_copy,
                .content = content,
            });
        }

        return extracted_files;
    }

    fn extractEntryContent(self: *EpubParser, file: *std.fs.File, entry: zip.Iterator.Entry) ![]u8 {
        const local_header_offset = entry.file_offset;
        try file.seekTo(local_header_offset);

        var header_bytes: [@sizeOf(zip.LocalFileHeader)]u8 = undefined;
        _ = try file.readAll(&header_bytes);
        const local_header: *align(1) zip.LocalFileHeader = @ptrCast(&header_bytes);
        if (!is_le) std.mem.byteSwapAllFields(zip.LocalFileHeader, local_header);
        if (!std.mem.eql(u8, &local_header.signature, &zip.local_file_header_sig)) {
            return error.ZipBadFileOffset;
        }

        const file_data_offset = local_header_offset +
            @sizeOf(zip.LocalFileHeader) +
            local_header.filename_len +
            local_header.extra_len;

        try file.seekTo(file_data_offset);

        const uncompressed_data = try self.allocator.alloc(u8, entry.uncompressed_size);
        errdefer self.allocator.free(uncompressed_data);

        switch (entry.compression_method) {
            .store => {
                _ = try file.readAll(uncompressed_data);
            },
            .deflate => {
                const compressed_data = try self.allocator.alloc(u8, entry.compressed_size);
                defer self.allocator.free(compressed_data);
                _ = try file.readAll(compressed_data);

                var io_reader = std.Io.Reader.fixed(compressed_data);

                var decompress_window: [std.compress.flate.max_window_len]u8 = undefined;
                var decompress = std.compress.flate.Decompress.init(&io_reader, .raw, &decompress_window);

                var total_read: usize = 0;
                while (total_read < entry.uncompressed_size) {
                    const remaining = entry.uncompressed_size - total_read;
                    const to_read = @min(remaining, 1024);
                    const chunk = uncompressed_data[total_read .. total_read + to_read];
                    const read_count = try decompress.reader.readSliceShort(chunk);
                    if (read_count == 0) break;
                    total_read += read_count;
                }
            },
            else => {
                return error.UnsupportedCompressionMethod;
            },
        }

        return uncompressed_data;
    }

    fn parseContainerXml(content: []const u8) ![]const u8 {
        const start_marker = "full-path=\"";
        const start_pos = std.mem.indexOf(u8, content, start_marker) orelse return error.OPFPathNotFound;
        const path_start = start_pos + start_marker.len;

        const end_pos = std.mem.indexOfScalarPos(u8, content, path_start, '"') orelse return error.OPFPathNotFound;

        return content[path_start..end_pos];
    }

    fn parseContentOpf(self: *EpubParser, content: []const u8, epub: *Epub) !void {
        try self.parseMetadata(content, epub);
        try self.parseManifest(content, epub);
        try self.parseSpine(content, epub);
    }

    fn parseMetadata(self: *EpubParser, content: []const u8, epub: *Epub) !void {
        const metadata_start = std.mem.indexOf(u8, content, "<metadata") orelse return;
        const metadata_end = std.mem.indexOfPos(u8, content, metadata_start, "</metadata>") orelse return;
        const metadata_section = content[metadata_start..metadata_end];

        if (self.extractXmlElementText(metadata_section, "dc:title")) |title| {
            epub.metadata.title = try self.allocator.dupe(u8, title);
        }

        if (self.extractXmlElementText(metadata_section, "dc:creator")) |creator| {
            epub.metadata.creator = try self.allocator.dupe(u8, creator);
        }

        if (self.extractXmlElementText(metadata_section, "dc:language")) |language| {
            epub.metadata.language = try self.allocator.dupe(u8, language);
        }

        if (self.extractXmlElementText(metadata_section, "dc:identifier")) |identifier| {
            epub.metadata.identifier = try self.allocator.dupe(u8, identifier);
        }
    }

    fn parseManifest(self: *EpubParser, content: []const u8, epub: *Epub) !void {
        const manifest_start = std.mem.indexOf(u8, content, "<manifest") orelse return;
        const manifest_end = std.mem.indexOfPos(u8, content, manifest_start, "</manifest>") orelse return;
        const manifest_section = content[manifest_start..manifest_end];

        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, manifest_section, pos, "<item ")) |item_start| {
            const item_end = std.mem.indexOfPos(u8, manifest_section, item_start, "/>") orelse break;
            const item_tag = manifest_section[item_start .. item_end + 2];

            const id = self.extractXmlAttribute(item_tag, "id") orelse "";
            const href = self.extractXmlAttribute(item_tag, "href") orelse "";
            const media_type = self.extractXmlAttribute(item_tag, "media-type") orelse "";

            if (id.len > 0 and href.len > 0 and media_type.len > 0) {
                try epub.manifest.append(self.allocator, .{
                    .id = try self.allocator.dupe(u8, id),
                    .href = try self.allocator.dupe(u8, href),
                    .media_type = try self.allocator.dupe(u8, media_type),
                });
            }

            pos = item_end + 2;
        }
    }

    fn parseSpine(self: *EpubParser, content: []const u8, epub: *Epub) !void {
        const spine_start = std.mem.indexOf(u8, content, "<spine") orelse return;
        const spine_end = std.mem.indexOfPos(u8, content, spine_start, "</spine>") orelse return;
        const spine_section = content[spine_start..spine_end];

        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, spine_section, pos, "<itemref ")) |itemref_start| {
            const itemref_end = std.mem.indexOfPos(u8, spine_section, itemref_start, "/>") orelse break;
            const itemref_tag = spine_section[itemref_start .. itemref_end + 2];

            const idref = self.extractXmlAttribute(itemref_tag, "idref") orelse "";

            if (idref.len > 0) {
                try epub.spine.append(self.allocator, .{
                    .idref = try self.allocator.dupe(u8, idref),
                });
            }

            pos = itemref_end + 2;
        }
    }

    fn extractXmlElementText(self: *EpubParser, content: []const u8, element_name: []const u8) ?[]const u8 {
        const start_tag = std.fmt.allocPrint(self.allocator, "<{s}", .{element_name}) catch return null;
        defer self.allocator.free(start_tag);

        const end_tag = std.fmt.allocPrint(self.allocator, "</{s}>", .{element_name}) catch return null;
        defer self.allocator.free(end_tag);

        const start_pos = std.mem.indexOf(u8, content, start_tag) orelse return null;
        const tag_end = std.mem.indexOfScalarPos(u8, content, start_pos, '>') orelse return null;
        const content_start = tag_end + 1;

        const content_end = std.mem.indexOfPos(u8, content, content_start, end_tag) orelse return null;

        return content[content_start..content_end];
    }

    fn extractXmlAttribute(self: *EpubParser, tag: []const u8, attr_name: []const u8) ?[]const u8 {
        const attr_start = std.fmt.allocPrint(self.allocator, "{s}=\"", .{attr_name}) catch return null;
        defer self.allocator.free(attr_start);

        const start_pos = std.mem.indexOf(u8, tag, attr_start) orelse return null;
        const value_start = start_pos + attr_start.len;

        const value_end = std.mem.indexOfScalarPos(u8, tag, value_start, '"') orelse return null;

        return tag[value_start..value_end];
    }
};
