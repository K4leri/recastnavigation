//! Интерфейсы Sample / SampleTool / SampleToolState и общие типы (аналог Sample.h).
//! Конкретные реализации — sample_solo.zig / sample_tile.zig / sample_temp_obstacles.zig
//! и tool_*.zig.

const std = @import("std");
const dvui = @import("dvui");
const recast = @import("recast-nav");
const ui = @import("ui.zig");

// ============================================================================
// Enums (1в1 с RecastDemo/Sample.h)
// ============================================================================

pub const SamplePartitionType = enum(u8) {
    watershed = 0,
    monotone = 1,
    layers = 2,
};

pub const SamplePolyAreas = enum(u8) {
    ground = 0,
    water = 1,
    road = 2,
    door = 3,
    grass = 4,
    jump = 5,
};

pub const SamplePolyFlags = struct {
    pub const walk: u16 = 0x01; // ходьба по земле/дороге/траве
    pub const swim: u16 = 0x02; // плавание (вода)
    pub const door: u16 = 0x04; // дверь
    pub const jump: u16 = 0x08; // прыжок
    pub const disabled: u16 = 0x10; // отключено
    pub const all: u16 = 0xffff;
};

pub const SampleToolType = enum(u8) {
    none = 0,
    tile_edit,
    tile_highlight,
    temp_obstacle,
    navmesh_tester,
    navmesh_prune,
    offmesh_connection,
    convex_volume,
    crowd,
};

/// Цвет области для отрисовки navmesh (Sample::SampleDebugDraw::areaToCol).
/// Теперь берётся из рантайм-реестра типов (area_types) — цвет редактируемый,
/// поддержаны пользовательские типы. Неизвестная область -> красный (как оригинал).
pub fn sampleAreaToCol(area: u32) u32 {
    return @import("area_types.zig").colorFor(area);
}

// ============================================================================
// Общие настройки сборки (Sample base — общие поля)
// ============================================================================

pub const CommonSettings = struct {
    cell_size: f32 = 0.3,
    cell_height: f32 = 0.2,
    agent_height: f32 = 2.0,
    agent_radius: f32 = 0.6,
    agent_max_climb: f32 = 0.9,
    agent_max_slope: f32 = 45.0,
    region_min_size: f32 = 8.0,
    region_merge_size: f32 = 20.0,
    edge_max_len: f32 = 12.0,
    edge_max_error: f32 = 1.3,
    verts_per_poly: f32 = 6.0,
    detail_sample_dist: f32 = 6.0,
    detail_sample_max_error: f32 = 1.0,
    partition_type: SamplePartitionType = .watershed,

    filter_low_hanging_obstacles: bool = true,
    filter_ledge_spans: bool = true,
    filter_walkable_low_height_spans: bool = true,
};

// ============================================================================
// Единая таблица k=v-настроек (источник истины для cli / headless / diff).
// ============================================================================

/// Имена всех float-полей CommonSettings (в порядке объявления). Используется
/// как diff-таблица (diff.zig) и для dispatch key->field в applySettingFloat.
/// Генерируется из самой структуры, чтобы не расходиться при добавлении полей.
pub const settings_float_field_names: []const []const u8 = blk: {
    const fields = @typeInfo(CommonSettings).@"struct".fields;
    var names: [fields.len][]const u8 = undefined;
    var n: usize = 0;
    for (fields) |f| {
        if (f.type == f32) {
            names[n] = f.name;
            n += 1;
        }
    }
    const final = names[0..n].*;
    break :blk &final;
};

/// Применить один float-ключ k=v к настройкам.
/// Поддержаны все float-поля CommonSettings + алиас `cells`/`cell_size` +
/// специальный `tile_size` (пишется в tile_size.*, т.к. это не поле структуры).
/// Возвращает true, если ключ распознан и значение применено; false — иначе.
pub fn applySettingFloat(s: *CommonSettings, tile_size: *?f32, key: []const u8, v: f32) bool {
    // `cells` — алиас cell_size.
    if (std.mem.eql(u8, key, "cells")) {
        s.cell_size = v;
        return true;
    }
    if (std.mem.eql(u8, key, "tile_size")) {
        tile_size.* = v;
        return true;
    }
    inline for (@typeInfo(CommonSettings).@"struct".fields) |f| {
        if (f.type == f32) {
            if (std.mem.eql(u8, key, f.name)) {
                @field(s, f.name) = v;
                return true;
            }
        }
    }
    return false;
}

/// true, если key — распознаваемый float-ключ настроек (включая `cells`/`tile_size`).
/// Для вызывающих, которым нужно отделить "неизвестный ключ" от "невалидное число".
pub fn isSettingFloatKey(key: []const u8) bool {
    if (std.mem.eql(u8, key, "cells") or std.mem.eql(u8, key, "tile_size")) return true;
    for (settings_float_field_names) |name| {
        if (std.mem.eql(u8, key, name)) return true;
    }
    return false;
}

/// Применить partition по строковому значению (watershed|monotone|layers).
/// Возвращает true при распознанном значении, false — иначе.
pub fn applyPartition(s: *CommonSettings, str: []const u8) bool {
    if (std.mem.eql(u8, str, "watershed")) {
        s.partition_type = .watershed;
    } else if (std.mem.eql(u8, str, "monotone")) {
        s.partition_type = .monotone;
    } else if (std.mem.eql(u8, str, "layers")) {
        s.partition_type = .layers;
    } else return false;
    return true;
}

/// Общие настройки сборки — порт Sample::drawCommonSettingsUI (1в1 порядок/диапазоны).
/// gw/gh — размер воксельной сетки (0 = скрыть строку Voxels).
pub fn drawCommonSettings(s: *CommonSettings, gw: i32, gh: i32) void {
    ui.section(@src(), "Rasterization");
    ui.slider(@src(), "Cell Size: {d:.2}", &s.cell_size, 0.1, 1.0);
    ui.slider(@src(), "Cell Height: {d:.2}", &s.cell_height, 0.1, 1.0);
    if (gw > 0) ui.rightText(@src(), "Voxels  {d} x {d}", .{ gw, gh });

    ui.section(@src(), "Agent");
    ui.slider(@src(), "Height: {d:.2}", &s.agent_height, 0.1, 5.0);
    ui.slider(@src(), "Radius: {d:.3}", &s.agent_radius, 0.0, 5.0);
    ui.slider(@src(), "Max Climb: {d:.2}", &s.agent_max_climb, 0.1, 5.0);
    ui.slider(@src(), "Max Slope: {d:.0}", &s.agent_max_slope, 0.0, 90.0);

    ui.section(@src(), "Region");
    ui.slider(@src(), "Min Region Size: {d:.0}", &s.region_min_size, 0.0, 150.0);
    ui.slider(@src(), "Merged Region Size: {d:.0}", &s.region_merge_size, 0.0, 150.0);

    ui.section(@src(), "Partitioning");
    if (ui.radio(@src(), s.partition_type == .watershed, "Watershed", 0)) s.partition_type = .watershed;
    if (ui.radio(@src(), s.partition_type == .monotone, "Monotone", 1)) s.partition_type = .monotone;
    if (ui.radio(@src(), s.partition_type == .layers, "Layers", 2)) s.partition_type = .layers;

    ui.section(@src(), "Filtering");
    _ = dvui.checkbox(@src(), &s.filter_low_hanging_obstacles, "Low Hanging Obstacles", .{});
    _ = dvui.checkbox(@src(), &s.filter_ledge_spans, "Ledge Spans", .{});
    _ = dvui.checkbox(@src(), &s.filter_walkable_low_height_spans, "Walkable Low Height Spans", .{});

    ui.section(@src(), "Polygonization");
    ui.slider(@src(), "Max Edge Length: {d:.0}", &s.edge_max_len, 0.0, 50.0);
    ui.slider(@src(), "Max Edge Error: {d:.1}", &s.edge_max_error, 0.1, 3.0);
    ui.sliderInt(@src(), "Verts Per Poly: {d:.0}", &s.verts_per_poly, 3.0, 12.0);

    ui.section(@src(), "Detail Mesh");
    ui.slider(@src(), "Sample Distance: {d:.0}", &s.detail_sample_dist, 0.0, 16.0);
    ui.slider(@src(), "Max Sample Error: {d:.0}", &s.detail_sample_max_error, 0.0, 16.0);
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
}

// ============================================================================
// Интерфейс SampleTool (инструменты: NavMeshTester, Crowd, ConvexVolume, ...)
// ============================================================================

pub const SampleTool = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        toolType: *const fn (ptr: *anyopaque) SampleToolType,
        reset: *const fn (ptr: *anyopaque) void,
        /// Отрисовка UI инструмента (dvui-виджеты) в панели Tools.
        drawMenu: *const fn (ptr: *anyopaque) void,
        /// Клик в сцене: rayStart/rayHit в мировых координатах.
        onClick: *const fn (ptr: *anyopaque, ray_start: *const [3]f32, ray_hit: *const [3]f32, shift: bool) void,
        onToggle: *const fn (ptr: *anyopaque) void,
        step: *const fn (ptr: *anyopaque) void,
        update: *const fn (ptr: *anyopaque, dt: f32) void,
        /// 3D-рендер инструмента через DebugDraw.
        render: *const fn (ptr: *anyopaque) void,
        /// Overlay-UI (текст в экранных координатах).
        renderOverlay: *const fn (ptr: *anyopaque) void,
    };

    pub fn toolType(self: SampleTool) SampleToolType {
        return self.vtable.toolType(self.ptr);
    }
    pub fn reset(self: SampleTool) void {
        self.vtable.reset(self.ptr);
    }
    pub fn drawMenu(self: SampleTool) void {
        self.vtable.drawMenu(self.ptr);
    }
    pub fn onClick(self: SampleTool, ray_start: *const [3]f32, ray_hit: *const [3]f32, shift: bool) void {
        self.vtable.onClick(self.ptr, ray_start, ray_hit, shift);
    }
    pub fn onToggle(self: SampleTool) void {
        self.vtable.onToggle(self.ptr);
    }
    pub fn step(self: SampleTool) void {
        self.vtable.step(self.ptr);
    }
    pub fn update(self: SampleTool, dt: f32) void {
        self.vtable.update(self.ptr, dt);
    }
    pub fn render(self: SampleTool) void {
        self.vtable.render(self.ptr);
    }
    pub fn renderOverlay(self: SampleTool) void {
        self.vtable.renderOverlay(self.ptr);
    }
};

// ============================================================================
// Интерфейс SampleToolState (persistent состояние инструмента: Crowd)
// ============================================================================

pub const SampleToolState = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        update: *const fn (ptr: *anyopaque, dt: f32) void,
        reset: *const fn (ptr: *anyopaque) void,
        render: *const fn (ptr: *anyopaque) void,
        renderOverlay: *const fn (ptr: *anyopaque) void,
    };

    pub fn update(self: SampleToolState, dt: f32) void {
        self.vtable.update(self.ptr, dt);
    }
    pub fn reset(self: SampleToolState) void {
        self.vtable.reset(self.ptr);
    }
    pub fn render(self: SampleToolState) void {
        self.vtable.render(self.ptr);
    }
    pub fn renderOverlay(self: SampleToolState) void {
        self.vtable.renderOverlay(self.ptr);
    }
};

// ============================================================================
// Интерфейс Sample (базовый класс сэмплов компиляции navmesh)
// ============================================================================

pub const Sample = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Параметры сборки + Load/Save (dvui).
        drawSettings: *const fn (ptr: *anyopaque) void,
        /// Выбор режима отрисовки (dvui).
        drawDebugMode: *const fn (ptr: *anyopaque) void,
        onClick: *const fn (ptr: *anyopaque, ray_start: *const [3]f32, ray_hit: *const [3]f32, shift: bool) void,
        onToggle: *const fn (ptr: *anyopaque) void,
        step: *const fn (ptr: *anyopaque) void,
        /// 3D-рендер (debug-draw текущего режима).
        render: *const fn (ptr: *anyopaque) void,
        renderOverlay: *const fn (ptr: *anyopaque) void,
        onMeshChanged: *const fn (ptr: *anyopaque) void,
        /// Построить navmesh. true при успехе.
        build: *const fn (ptr: *anyopaque) bool,
        update: *const fn (ptr: *anyopaque, dt: f32) void,
    };

    pub fn drawSettings(self: Sample) void {
        self.vtable.drawSettings(self.ptr);
    }
    pub fn drawDebugMode(self: Sample) void {
        self.vtable.drawDebugMode(self.ptr);
    }
    pub fn onClick(self: Sample, ray_start: *const [3]f32, ray_hit: *const [3]f32, shift: bool) void {
        self.vtable.onClick(self.ptr, ray_start, ray_hit, shift);
    }
    pub fn onToggle(self: Sample) void {
        self.vtable.onToggle(self.ptr);
    }
    pub fn step(self: Sample) void {
        self.vtable.step(self.ptr);
    }
    pub fn render(self: Sample) void {
        self.vtable.render(self.ptr);
    }
    pub fn renderOverlay(self: Sample) void {
        self.vtable.renderOverlay(self.ptr);
    }
    pub fn onMeshChanged(self: Sample) void {
        self.vtable.onMeshChanged(self.ptr);
    }
    pub fn build(self: Sample) bool {
        return self.vtable.build(self.ptr);
    }
    pub fn update(self: Sample, dt: f32) void {
        self.vtable.update(self.ptr, dt);
    }
};

test "area colors distinct" {
    try std.testing.expect(sampleAreaToCol(0) != sampleAreaToCol(5));
}
