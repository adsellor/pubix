const dvui = @import("dvui");

const Color = dvui.Color;

pub const mocha = struct {
    pub const base00 = Color{ .r = 0xF5, .g = 0xF0, .b = 0xED, .a = 0xFF };
    pub const base01 = Color{ .r = 0xE5, .g = 0xDB, .b = 0xD5, .a = 0xFF };
    pub const base02 = Color{ .r = 0xD0, .g = 0xC0, .b = 0xB8, .a = 0xFF };
    pub const base03 = Color{ .r = 0xB0, .g = 0x9C, .b = 0x92, .a = 0xFF };
    pub const base04 = Color{ .r = 0x8A, .g = 0x74, .b = 0x6A, .a = 0xFF };
    pub const base05 = Color{ .r = 0x66, .g = 0x4F, .b = 0x45, .a = 0xFF };
    pub const base06 = Color{ .r = 0x4D, .g = 0x3A, .b = 0x30, .a = 0xFF };
    pub const base07 = Color{ .r = 0x2C, .g = 0x21, .b = 0x1B, .a = 0xFF };
    pub const base08 = Color{ .r = 0x7D, .g = 0x53, .b = 0x3D, .a = 0xFF };
    pub const base09 = Color{ .r = 0xA1, .g = 0x6B, .b = 0x4F, .a = 0xFF };
    pub const base0A = Color{ .r = 0xC5, .g = 0x8F, .b = 0x6D, .a = 0xFF };
    pub const base0B = Color{ .r = 0x5E, .g = 0x39, .b = 0x2E, .a = 0xFF };
    pub const base0C = Color{ .r = 0x49, .g = 0x2E, .b = 0x24, .a = 0xFF };
    pub const base0D = Color{ .r = 0x3C, .g = 0x25, .b = 0x1C, .a = 0xFF };
    pub const base0E = Color{ .r = 0x34, .g = 0x1A, .b = 0x12, .a = 0xFF };
    pub const base0F = Color{ .r = 0x21, .g = 0x11, .b = 0x08, .a = 0xFF };
};

pub const reader_serif_family = "Vera Serif";
pub const reader_sans_family = "Vera Sans";
pub const reader_mono_family = "Vera Sans Mono";

pub const reader_fonts: []const dvui.Font.Source = dvui.Theme.builtin.adwaita_dark.embedded_fonts;

pub const base_font_size: f32 = 17;

pub const mocha_theme: dvui.Theme = blk: {
    @setEvalBranchQuota(4000);
    break :blk .{
        .name = "Mocha Dark",
        .dark = true,
        .embedded_fonts = reader_fonts,

        .font_body = .find(.{ .family = reader_serif_family, .size = base_font_size, .line_height_factor = 1.5 }),
        .font_heading = .find(.{ .family = reader_serif_family, .size = base_font_size, .weight = .bold, .line_height_factor = 1.4 }),
        .font_title = .find(.{ .family = reader_sans_family, .size = base_font_size + 6, .weight = .bold, .line_height_factor = 1.3 }),
        .font_mono = .find(.{ .family = reader_mono_family, .size = base_font_size - 3, .line_height_factor = 1.4 }),

        .focus = mocha.base0A,

        .fill = mocha.base07,
        .fill_hover = mocha.base06,
        .fill_press = mocha.base05,
        .text = mocha.base00,
        .text_select = mocha.base09,
        .border = mocha.base05,

        .control = .{
            .fill = mocha.base06,
            .fill_hover = mocha.base05,
            .fill_press = mocha.base04,
            .text = mocha.base00,
            .border = mocha.base04,
        },

        .window = .{
            .fill = mocha.base0F,
            .text = mocha.base00,
            .border = mocha.base05,
        },

        .highlight = .{
            .fill = mocha.base09,
            .fill_hover = mocha.base0A,
            .text = mocha.base00,
            .border = mocha.base0A,
        },

        .err = .{
            .fill = mocha.base0A,
            .text = mocha.base00,
            .border = mocha.base09,
        },
    };
};
