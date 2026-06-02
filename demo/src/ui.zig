//! Общие UI-хелперы для воспроизведения виджетов RecastDemo (imguiHelpers.h).

const std = @import("std");
const dvui = @import("dvui");

/// Заголовок секции — аналог ImGui::SeparatorText: разделитель + жирная подпись.
pub fn section(src: std.builtin.SourceLocation, comptime text: []const u8) void {
    _ = dvui.separator(src, .{ .expand = .horizontal, .id_extra = 0 });
    dvui.labelNoFmt(src, text, .{}, .{ .font = dvui.themeGet().font_heading, .id_extra = 1 });
}

/// Слайдер f32 с подписью (формат должен содержать одно поле {d:...}).
pub fn slider(src: std.builtin.SourceLocation, comptime fmt: []const u8, value: *f32, min: f32, max: f32) void {
    _ = dvui.sliderEntry(src, fmt, .{ .value = value, .min = min, .max = max, .interval = null }, .{ .expand = .horizontal });
}

/// Слайдер целого (через f32-прокси хранение в самом значении).
pub fn sliderInt(src: std.builtin.SourceLocation, comptime fmt: []const u8, value: *f32, min: f32, max: f32) void {
    _ = dvui.sliderEntry(src, fmt, .{ .value = value, .min = min, .max = max, .interval = 1 }, .{ .expand = .horizontal });
}

/// Radio-кнопка: возвращает true при клике. Тонкая обёртка над dvui.radio.
pub fn radio(src: std.builtin.SourceLocation, active: bool, label_str: []const u8, id_extra: usize) bool {
    return dvui.radio(src, active, label_str, .{ .id_extra = id_extra });
}

/// Текст, выровненный по правому краю (как DrawRightAlignedText).
pub fn rightText(src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    dvui.label(src, fmt, args, .{ .gravity_x = 1.0 });
}

/// Узел-раскрывашка (аналог ImGui::TreeNode) — возвращает раскрыт ли.
pub fn treeNode(src: std.builtin.SourceLocation, label_str: []const u8) bool {
    return dvui.expander(src, label_str, .{}, .{});
}

/// Текст в позиции экрана (физические пиксели, top-left). Вызывать внутри dvui-кадра
/// (между win.begin и win.end). Аналог imguiDrawText / DrawWorldspaceText.
///
/// ВАЖНО: rect ОБЯЗАН иметь ненулевой w/h — dvui.renderText на строке
/// `if (clipped_rect.empty()) return;` (render.zig) считает rect с w==0||h==0
/// пустым и НИЧЕГО не рисует. Поэтому считаем реальный размер строки через
/// font.textSize и кладём его в rs.r.
pub fn screenText(px: f32, py: f32, text: []const u8, color: dvui.Color) void {
    screenTextEx(px, py, text, color, false);
}

/// Как screenText, но `centered` центрирует строку по X относительно px
/// (повторяет DrawWorldspaceText(..., centered=true) из imguiHelpers.h —
/// подписи агентов/целей в RecastDemo центрируются по горизонтали).
pub fn screenTextEx(px: f32, py: f32, text: []const u8, color: dvui.Color, centered: bool) void {
    if (text.len == 0) return;
    const font = dvui.themeGet().font_body;
    const sz = font.textSize(text); // натуральные пиксели; rs.s = 1.0 => физические
    const x = if (centered) px - sz.w * 0.5 else px;
    const rs = dvui.RectScale{ .r = .{ .x = x, .y = py, .w = sz.w, .h = sz.h }, .s = 1.0 };
    // Лёгкая светлая подложка под тёмным текстом — оригинал рисует чёрный текст
    // через ImGui foreground поверх (более светлого) навмеша; на нашем тёмном
    // воксельном фоне без подложки чёрный нечитаем. Подложка полупрозрачная,
    // сохраняет "тёмный текст" дух оригинала и гарантирует видимость на любом фоне.
    // Подложка только под ТЁМНЫЙ текст (светлая) — чёрные подписи нечитаемы на тёмном
    // воксельном фоне. Светлый текст рисуем без подложки (как оригинал).
    const bg: ?dvui.Color = if (color.r < 128 and color.g < 128 and color.b < 128)
        dvui.Color{ .r = 255, .g = 255, .b = 255, .a = 160 }
    else
        null;
    dvui.renderText(.{
        .font = font,
        .text = text,
        .rs = rs,
        .color = color,
        .background_color = bg,
    }) catch {};
}
