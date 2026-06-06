//! Общие UI-хелперы для воспроизведения виджетов RecastDemo (imguiHelpers.h).

const std = @import("std");
const dvui = @import("dvui");

/// Заголовок секции — аналог ImGui::SeparatorText: разделитель + жирная подпись.
pub fn section(src: std.builtin.SourceLocation, comptime text: []const u8) void {
    _ = dvui.separator(src, .{ .expand = .horizontal, .id_extra = 0 });
    dvui.labelNoFmt(src, text, .{}, .{ .font = dvui.themeGet().font_heading, .id_extra = 1 });
}

// Drag-only слайдер с подписью значения. Чистый `dvui.slider` (по доле 0..1,
// БЕЗ text-ввода с клавиатуры) вместо `dvui.sliderEntry`: у последнего режим
// ввода значения с клавиатуры захватывал клавиатуру и делал остальное
// приложение неуправляемым. Метка и слайдер делят `src`, слайдер получает
// id_extra=1, чтобы dvui-id не конфликтовали (как в `section` выше).
fn dragSlider(src: std.builtin.SourceLocation, comptime fmt: []const u8, value: *f32, min: f32, max: f32, step: ?f32) void {
    var hb = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer hb.deinit();
    var lbuf: [96]u8 = undefined;
    const txt = std.fmt.bufPrint(&lbuf, fmt, .{value.*}) catch fmt;
    dvui.labelNoFmt(src, txt, .{}, .{ .gravity_y = 0.5 });
    var frac: f32 = if (max > min) (value.* - min) / (max - min) else 0;
    frac = std.math.clamp(frac, 0, 1);
    if (dvui.slider(src, .{ .fraction = &frac }, .{ .expand = .horizontal, .id_extra = 1, .gravity_y = 0.5 })) {
        var v = min + frac * (max - min);
        if (step) |s| v = min + @round((v - min) / s) * s;
        value.* = std.math.clamp(v, min, max);
    }
}

/// Слайдер f32 с подписью (формат должен содержать одно поле {d:...}).
pub fn slider(src: std.builtin.SourceLocation, comptime fmt: []const u8, value: *f32, min: f32, max: f32) void {
    dragSlider(src, fmt, value, min, max, null);
}

/// Слайдер целого (через f32-прокси хранение в самом значении).
pub fn sliderInt(src: std.builtin.SourceLocation, comptime fmt: []const u8, value: *f32, min: f32, max: f32) void {
    dragSlider(src, fmt, value, min, max, 1);
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
    // No backdrop: worldspace labels render as plain text (1:1 with the original,
    // which draws the label straight to the foreground without a background box).
    dvui.renderText(.{
        .font = font,
        .text = text,
        .rs = rs,
        .color = color,
        .background_color = null,
    }) catch {};
}

/// Распаковать упакованный debug-`rgba` u32 (R в младшем байте, layout 0xAABBGGRR
/// — как у debug-draw / dbg.rgba) в `dvui.Color`, СОХРАНЯЯ альфу. Каноничный
/// распаковщик: раньше дублировался в value_history.col и render/legend.toDvui.
pub fn colorFromRgba(col: u32) dvui.Color {
    return .{
        .r = @intCast(col & 0xff),
        .g = @intCast((col >> 8) & 0xff),
        .b = @intCast((col >> 16) & 0xff),
        .a = @intCast((col >> 24) & 0xff),
    };
}

/// Как colorFromRgba, но форсирует полную непрозрачность (a=255) — для swatch'ей,
/// которые должны читаться сплошным цветом независимо от упакованной альфы.
/// Раньше дублировался в tool_navmesh_tester.colToDvui.
pub fn colorFromRgbaOpaque(col: u32) dvui.Color {
    return .{
        .r = @intCast(col & 0xff),
        .g = @intCast((col >> 8) & 0xff),
        .b = @intCast((col >> 16) & 0xff),
        .a = 255,
    };
}
