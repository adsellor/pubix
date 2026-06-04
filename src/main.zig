const std = @import("std");
const pubix = @import("pubix");
const fileReader = @import("epub/file_reader.zig");
const sdl3 = @import("reader/sdl3.zig");

const EpubParser = fileReader.EpubParser;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();

    var args_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (args_list.items) |a| allocator.free(a);
        args_list.deinit(allocator);
    }
    while (args_iter.next()) |a| {
        try args_list.append(allocator, try allocator.dupe(u8, a));
    }
    const args = args_list.items;

    // if (args.len < 2) {
    //     std.debug.print("Usage: {s} <epub_file> [options]\n", .{args[0]});
    //     std.debug.print("\nOptions:\n", .{});
    //     std.debug.print("  --chapters       Show all chapters in reading order\n", .{});
    //     std.debug.print("  --chapters-html  Show chapters with titles and HTML content\n", .{});
    //     std.debug.print("  --chapter <n>    Show specific chapter by number\n", .{});
    //     std.debug.print("  --images        Show all images\n", .{});
    //     std.debug.print("  --files         Show all files\n", .{});
    //     std.debug.print("  --toc           Show table of contents\n", .{});
    //     std.debug.print("  --cover         Show cover content\n", .{});
    //     std.debug.print("\nExamples:\n", .{});
    //     std.debug.print("  {s} book.epub                    # Parse and show metadata\n", .{args[0]});
    //     std.debug.print("  {s} book.epub --chapters         # Show chapters\n", .{args[0]});
    //     std.debug.print("  {s} book.epub --images           # Show images\n", .{args[0]});
    //     return;
    // }
    //
    // var parser = EpubParser.init(allocator);
    //
    // std.debug.print("Parsing EPUB: {s}\n", .{args[1]});
    // var epub = try parser.parseEpub(args[1]);
    // defer epub.deinit();
    //
    // std.debug.print("\n=== EPUB Metadata ===\n", .{});
    // if (epub.metadata.title) |title| {
    //     std.debug.print("Title: {s}\n", .{title});
    // }
    // if (epub.metadata.creator) |creator| {
    //     std.debug.print("Author: {s}\n", .{creator});
    // }
    // if (epub.metadata.language) |language| {
    //     std.debug.print("Language: {s}\n", .{language});
    // }
    // if (epub.metadata.identifier) |identifier| {
    //     std.debug.print("Identifier: {s}\n", .{identifier});
    // }
    //
    // std.debug.print("Total files: {d}\n", .{epub.files.items.len});
    // std.debug.print("Manifest items: {d}\n", .{epub.manifest.items.len});
    // std.debug.print("Spine items: {d}\n", .{epub.spine.items.len});
    //
    // // Handle options
    // if (args.len >= 3) {
    //     const option = args[2];
    //
    //     if (std.mem.eql(u8, option, "--chapters")) {
    //         std.debug.print("\n=== Chapters (Reading Order) ===\n", .{});
    //         var chapters = try epub.getOrderedChapters();
    //         defer chapters.deinit(allocator);
    //
    //         for (chapters.items, 0..) |chapter, i| {
    //             std.debug.print("{d}. {s} ({d} bytes)\n", .{ i + 1, chapter.filename, chapter.content.len });
    //         }
    //     } else if (std.mem.eql(u8, option, "--images")) {
    //         std.debug.print("\n=== Images ===\n", .{});
    //         var images = try epub.getImages();
    //         defer images.deinit(allocator);
    //
    //         for (images.items) |image| {
    //             std.debug.print("- {s} ({d} bytes)\n", .{ image.filename, image.content.len });
    //         }
    //     } else if (std.mem.eql(u8, option, "--files")) {
    //         std.debug.print("\n=== All Files ===\n", .{});
    //         for (epub.getAllFiles()) |file| {
    //             std.debug.print("- {s} ({d} bytes)\n", .{ file.filename, file.content.len });
    //         }
    //     } else if (std.mem.eql(u8, option, "--toc")) {
    //         std.debug.print("\n=== Table of Contents ===\n", .{});
    //         if (epub.getTocContent()) |toc_content| {
    //             const preview_len = @min(toc_content.len, 500);
    //             std.debug.print("{s}...\n", .{toc_content[0..preview_len]});
    //         } else {
    //             std.debug.print("No table of contents found\n", .{});
    //         }
    //     } else if (std.mem.eql(u8, option, "--chapters-html")) {
    //         std.debug.print("\n=== Chapters with HTML Content ===\n", .{});
    //         var chapters = try epub.getChapters();
    //         defer {
    //             for (chapters.items) |*chapter| {
    //                 chapter.deinit(allocator);
    //             }
    //             chapters.deinit(allocator);
    //         }
    //
    //         for (chapters.items) |chapter| {
    //             std.debug.print("\n--- Chapter {d}: {s} ---\n", .{ chapter.chapter_number, chapter.title });
    //             std.debug.print("File: {s}\n", .{chapter.filename});
    //             const preview_len = @min(chapter.html_content.len, 300);
    //             std.debug.print("HTML (first 300 chars): {s}...\n", .{chapter.html_content[0..preview_len]});
    //         }
    //     } else if (std.mem.eql(u8, option, "--chapter") and args.len >= 4) {
    //         const chapter_num = std.fmt.parseInt(usize, args[3], 10) catch {
    //             std.debug.print("Invalid chapter number: {s}\n", .{args[3]});
    //             return;
    //         };
    //
    //         std.debug.print("\n=== Chapter {d} ===\n", .{chapter_num});
    //         if (try epub.getChapter(chapter_num - 1)) |chapter| {
    //             defer {
    //                 var mut_chapter = chapter;
    //                 mut_chapter.deinit(allocator);
    //             }
    //
    //             std.debug.print("Title: {s}\n", .{chapter.title});
    //             std.debug.print("File: {s}\n", .{chapter.filename});
    //             std.debug.print("HTML Content ({d} bytes):\n", .{chapter.html_content.len});
    //             std.debug.print("{s}\n", .{chapter.html_content});
    //         } else {
    //             std.debug.print("Chapter {d} not found\n", .{chapter_num});
    //         }
    //     } else if (std.mem.eql(u8, option, "--cover")) {
    //         std.debug.print("\n=== Cover ===\n", .{});
    //         if (epub.getCoverContent()) |cover_content| {
    //             const preview_len = @min(cover_content.len, 500);
    //             std.debug.print("{s}...\n", .{cover_content[0..preview_len]});
    //         } else {
    //             std.debug.print("No cover found\n", .{});
    //         }
    //     } else {
    //         std.debug.print("Unknown option: {s}\n", .{option});
    //     }
    // }

    const epub_file = if (args.len > 1) args[1] else null;
    try sdl3.example(allocator, init.io, init.environ_map, epub_file);
}
