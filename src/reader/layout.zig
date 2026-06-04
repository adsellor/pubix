const dvui = @import("dvui");

pub const Layout = enum { single, double };

pub const column_max_width: f32 = 700;
pub const column_min_width: f32 = 320;
pub const column_gutter: f32 = 60;
pub const page_outer_margin: f32 = 30;
pub const top_bar_height: f32 = 64;

pub const image_max_height: f32 = 480;
pub const image_max_width: f32 = 640;
pub const image_vertical_margin: f32 = 10;

pub fn computeLayout(window_width: f32) Layout {
    const threshold = 2 * column_max_width + column_gutter + 2 * page_outer_margin;
    return if (window_width >= threshold) .double else .single;
}

pub fn computeColumnWidth(window_width: f32, layout: Layout) f32 {
    return switch (layout) {
        .single => @max(@min(window_width - 2 * page_outer_margin, column_max_width), column_min_width),
        .double => column_max_width,
    };
}

pub fn computeImageDisplaySize(natural: dvui.Size, max_width: f32, max_height: f32) dvui.Size {
    if (natural.w <= 0 or natural.h <= 0) return .{ .w = 0, .h = 0 };

    const limit_w = @min(max_width, image_max_width);
    var w = natural.w;
    var h = natural.h;

    if (w > limit_w) {
        const scale = limit_w / w;
        w = limit_w;
        h *= scale;
    }
    if (h > max_height) {
        const scale = max_height / h;
        h = max_height;
        w *= scale;
    }

    return .{ .w = w, .h = h };
}
