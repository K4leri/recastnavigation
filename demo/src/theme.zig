//! Dark, semi-transparent dvui theme mimicking the original RecastDemo's
//! Dear ImGui "dark" style (dark translucent panels, light gray text).
//!
//! Built on top of dvui's builtin `adwaita_dark` theme so we reuse its
//! already-embedded Vera Sans fonts (no extra font loading), and only
//! override the colors to match the ImGui-dark reference targets.

const dvui = @import("dvui");

const Color = dvui.Color;

// --- Reference target colors (Dear ImGui dark, 0-255) ---

/// Window/panel background: dark, semi-transparent so the 3D scene shows
/// through faintly (alpha < 255), like the original.
const window_fill = Color{ .r = 25, .g = 27, .b = 31, .a = 192 };

/// Header/title bar background: slightly lighter dark.
const header_fill = Color{ .r = 40, .g = 44, .b = 52, .a = 200 };

/// Light gray text.
const text_col = Color{ .r = 220, .g = 222, .b = 225, .a = 255 };

/// Widget fill (sliders/checkbox bg) and its hover/press states.
const control_fill = Color{ .r = 45, .g = 50, .b = 58, .a = 210 };
const control_fill_hover = Color{ .r = 58, .g = 64, .b = 74, .a = 230 };

/// ImGui's selected blue (accent / pressed).
const accent_blue = Color{ .r = 40, .g = 110, .b = 220, .a = 255 };

/// Subtle borders/separators.
const border_col = Color{ .r = 70, .g = 74, .b = 82, .a = 160 };

/// The base content fill (textLayout/textEntry backgrounds) — keep it
/// translucent-dark too so panels read as a single dark sheet.
const content_fill = Color{ .r = 30, .g = 33, .b = 38, .a = 192 };

/// Build the theme by starting from `adwaita_dark` and overriding colors.
pub const imgui_dark: dvui.Theme = blk: {
    var t = dvui.Theme.builtin.adwaita_dark;

    t.name = "ImGui Dark";
    t.dark = true;

    // Focus / accent highlight ring.
    t.focus = accent_blue;

    // Base (.content) style: backgrounds of text areas, general foreground.
    t.fill = content_fill;
    t.fill_hover = control_fill_hover;
    t.fill_press = accent_blue;
    t.text = text_col;
    t.text_hover = text_col;
    t.text_press = text_col;
    t.border = border_col;

    // Small corner radius, compact look.
    t.max_default_corner_radius = 3;

    // Normal controls (buttons, sliders, checkboxes, dropdowns).
    t.control = .{
        .fill = control_fill,
        .fill_hover = control_fill_hover,
        .fill_press = accent_blue,
        .text = text_col,
        .text_press = text_col,
        .border = border_col,
    };

    // Windows / boxes (scrollArea, floatingWindow body) — translucent dark.
    t.window = .{
        .fill = window_fill,
        .text = text_col,
        .border = border_col,
    };

    // Highlight: menu/dropdown selection, checked checkboxes, radio buttons.
    t.highlight = .{
        .fill = accent_blue,
        .fill_hover = Color{ .r = 60, .g = 130, .b = 235, .a = 255 },
        .fill_press = Color{ .r = 30, .g = 95, .b = 200, .a = 255 },
        .text = Color.white,
        .border = accent_blue,
    };

    break :blk t;
};

/// Header/title-bar background color, exposed so the window header can use a
/// slightly lighter shade than the panel body if desired.
pub const header_background = header_fill;
