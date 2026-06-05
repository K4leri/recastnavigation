//! nav_export — обвязка экспорта навмеша в GUI-демо (cluster D, D2/D3/D7).
//!
//! Чистые форматтеры живут в export_metrics/export_obj/export_gltf/export_svg.zig
//! (зависят только от std). Этот модуль выполняет READ-ONLY обход живого
//! dt.NavMesh (форма обхода 1:1 с tool_navmesh_tester.drawPolySafe — все доступы
//! к detail-мешу bounds-checked, ни один битый ref не может выйти за границы) и
//! упаковывает результат в структуры/срезы, пригодные форматтерам.
//!
//! ВЛАДЕНИЕ ПАМЯТЬЮ:
//!   - gatherMetrics возвращает MetricsOwned: содержит export_metrics.Metrics +
//!     owned-срез areas. Caller обязан вызвать .deinit(alloc). Поле .metrics
//!     ссылается на .areas, поэтому НЕ переживает deinit. source_geom/
//!     source_sample/partition НЕ копируются (caller держит их живыми).
//!   - navTriangles/navObjFaces/navPolys2D возвращают структуры с owned-срезами и
//!     методом deinit(alloc). Caller обязан вызвать deinit.
//!
//! ЦВЕТ AREA для SVG берётся из area_types.colorFor(area) (рантайм-реестр,
//! редактируемый в GUI). Формат там — recast.debug.rgba(r,g,b,a) = 0xAABBGGRR
//! (см. ниже packRgb): извлекаем r/g/b из реестра напрямую и пакуем в 0x00RRGGBB,
//! как требует export_svg.

const std = @import("std");
const recast = @import("recast-nav");
const export_metrics = @import("export_metrics.zig");
const area_types = @import("../area_types.zig");
const sample = @import("../sample.zig");

const dt = recast.detour;

// ===========================================================================
// Metrics
// ===========================================================================

/// Owned-обёртка вокруг export_metrics.Metrics: владеет срезом areas.
/// `metrics.areas` указывает на `areas` — он валиден только до deinit.
pub const MetricsOwned = struct {
    metrics: export_metrics.Metrics,
    areas: []export_metrics.AreaCount,

    pub fn deinit(self: *MetricsOwned, alloc: std.mem.Allocator) void {
        alloc.free(self.areas);
        self.* = undefined;
    }
};

/// Собрать Metrics из навмеша + настроек. Caller владеет результатом (deinit).
/// `source_geom`/`source_sample` НЕ копируются — caller держит строки живыми.
pub fn gatherMetrics(
    alloc: std.mem.Allocator,
    mesh: *const dt.NavMesh,
    s: *const sample.CommonSettings,
    source_geom: []const u8,
    source_sample: []const u8,
    bmin: [3]f32,
    bmax: [3]f32,
    build_ms: f32,
    tile_size: ?f32,
) !MetricsOwned {
    // navmesh counts + per-area poly-count (обход всех тайлов/полигонов).
    var num_tiles: u32 = 0;
    var num_polys: u32 = 0;
    var num_verts: u32 = 0;
    // per-area счётчик: area в [0,63] (DT_MAX_AREAS=64).
    var area_polys = [_]u32{0} ** area_types.MAX_AREA_TYPES;

    for (mesh.tiles) |*t| {
        const hdr = t.header orelse continue;
        if (t.data_size == 0) continue;
        num_tiles += 1;
        num_verts += @intCast(@max(hdr.vert_count, 0));
        const pc: usize = @intCast(@max(hdr.poly_count, 0));
        num_polys += @intCast(pc);
        var pi: usize = 0;
        while (pi < pc and pi < t.polys.len) : (pi += 1) {
            const a = t.polys[pi].getArea();
            if (a < area_types.MAX_AREA_TYPES) area_polys[a] += 1;
        }
    }

    // Собрать areas: только те area-id, у которых есть полигоны ЛИБО которые
    // зарегистрированы в реестре с ненулевым счётчиком. Берём id с poly_count>0
    // (порядок по возрастанию id — детерминирован для diff D6).
    var areas = std.array_list.Managed(export_metrics.AreaCount).init(alloc);
    errdefer areas.deinit();
    for (area_polys, 0..) |cnt, id| {
        if (cnt == 0) continue;
        const nm: []const u8 = if (area_types.get(id)) |at| at.name() else "Unknown";
        try areas.append(.{ .id = @intCast(id), .name = nm, .poly_count = cnt });
    }
    const areas_owned = try areas.toOwnedSlice();
    errdefer alloc.free(areas_owned);

    const metrics = export_metrics.Metrics{
        .source_geom = source_geom,
        .source_sample = source_sample,
        .cell_size = s.cell_size,
        .cell_height = s.cell_height,
        .agent_height = s.agent_height,
        .agent_radius = s.agent_radius,
        .agent_max_climb = s.agent_max_climb,
        .agent_max_slope = s.agent_max_slope,
        .region_min_size = s.region_min_size,
        .region_merge_size = s.region_merge_size,
        .edge_max_len = s.edge_max_len,
        .edge_max_error = s.edge_max_error,
        .verts_per_poly = s.verts_per_poly,
        .detail_sample_dist = s.detail_sample_dist,
        .detail_sample_max_error = s.detail_sample_max_error,
        .partition = @tagName(s.partition_type),
        .tile_size = tile_size,
        .bmin = bmin,
        .bmax = bmax,
        .num_tiles = num_tiles,
        .num_polys = num_polys,
        .num_verts = num_verts,
        .max_polys = @intCast(@max(mesh.params.max_polys, 0)),
        .areas = areas_owned,
        .build_ms = build_ms,
    };

    return .{ .metrics = metrics, .areas = areas_owned };
}

// ===========================================================================
// Геометрия: общий безопасный обход detail-меша
// ===========================================================================

/// Извлечь world-space координаты вершины `k` детального треугольника `t`
/// (stride 4 в detail_tris). Возвращает null если индекс вне границ (bounds-safe,
/// как в drawPolySafe). vc = poly.vert_count.
fn detailVert(
    t: *const dt.MeshTile,
    poly: *const dt.Poly,
    pd: *const dt.PolyDetail,
    vc: usize,
    tk: u8,
) ?[3]f32 {
    if (tk < vc) {
        if (@as(usize, tk) >= poly.verts.len) return null;
        const v_idx = @as(usize, poly.verts[tk]) * 3;
        if (v_idx + 2 >= t.verts.len) return null;
        return .{ t.verts[v_idx], t.verts[v_idx + 1], t.verts[v_idx + 2] };
    } else {
        const d_idx = (@as(usize, pd.vert_base) + (@as(usize, tk) - vc)) * 3;
        if (d_idx + 2 >= t.detail_verts.len) return null;
        return .{ t.detail_verts[d_idx], t.detail_verts[d_idx + 1], t.detail_verts[d_idx + 2] };
    }
}

// ===========================================================================
// Треугольная геометрия для glTF (.glb)
// ===========================================================================

pub const TriGeom = struct {
    verts: []f32, // плоские тройки x,y,z
    indices: []u32, // плоские индексы треугольников (кратно 3)

    pub fn deinit(self: *TriGeom, alloc: std.mem.Allocator) void {
        alloc.free(self.verts);
        alloc.free(self.indices);
        self.* = undefined;
    }
};

/// Собрать триангулированную геометрию навмеша (детальные треугольники).
/// Каждый треугольник получает 3 собственные вершины (без шаринга) — это просто
/// и безопасно; для экспорта-визуализации дедупликация не нужна.
pub fn navTriangles(alloc: std.mem.Allocator, mesh: *const dt.NavMesh) !TriGeom {
    var verts = std.array_list.Managed(f32).init(alloc);
    errdefer verts.deinit();
    var indices = std.array_list.Managed(u32).init(alloc);
    errdefer indices.deinit();

    var next: u32 = 0;
    for (mesh.tiles) |*t| {
        const hdr = t.header orelse continue;
        if (t.data_size == 0) continue;
        const pc: usize = @intCast(@max(hdr.poly_count, 0));
        var pi: usize = 0;
        while (pi < pc and pi < t.polys.len and pi < t.detail_meshes.len) : (pi += 1) {
            const poly = &t.polys[pi];
            const pd = &t.detail_meshes[pi];
            const vc: usize = poly.vert_count;
            var ti: usize = 0;
            while (ti < @as(usize, pd.tri_count)) : (ti += 1) {
                const t_idx = (@as(usize, pd.tri_base) + ti) * 4;
                if (t_idx + 3 >= t.detail_tris.len) break;
                const tri = t.detail_tris[t_idx .. t_idx + 4];
                var p: [3][3]f32 = undefined;
                var ok = true;
                for (0..3) |k| {
                    if (detailVert(t, poly, pd, vc, tri[k])) |v| {
                        p[k] = v;
                    } else {
                        ok = false;
                        break;
                    }
                }
                if (!ok) continue;
                for (0..3) |k| {
                    try verts.append(p[k][0]);
                    try verts.append(p[k][1]);
                    try verts.append(p[k][2]);
                    try indices.append(next);
                    next += 1;
                }
            }
        }
    }

    // toOwnedSlice по очереди с errdefer: если второй вызов падает (OOM), первый
    // уже-owned срез не утечёт (errdefer verts.deinit() — no-op после toOwnedSlice).
    const verts_owned = try verts.toOwnedSlice();
    errdefer alloc.free(verts_owned);
    const indices_owned = try indices.toOwnedSlice();
    return .{ .verts = verts_owned, .indices = indices_owned };
}

// ===========================================================================
// Полигоны произвольной арности для .obj
// ===========================================================================

pub const ObjGeom = struct {
    verts: []f32,
    faces_flat: []u32,
    face_sizes: []u32,

    pub fn deinit(self: *ObjGeom, alloc: std.mem.Allocator) void {
        alloc.free(self.verts);
        alloc.free(self.faces_flat);
        alloc.free(self.face_sizes);
        self.* = undefined;
    }
};

/// Собрать полигоны навмеша как грани .obj. Используем ИСХОДНЫЕ poly-вершины
/// (poly.verts[0..vert_count]) — грани произвольной арности (3..6), .obj это
/// поддерживает. Вершины эмитятся per-face (без шаринга) — просто и безопасно.
pub fn navObjFaces(alloc: std.mem.Allocator, mesh: *const dt.NavMesh) !ObjGeom {
    var verts = std.array_list.Managed(f32).init(alloc);
    errdefer verts.deinit();
    var faces_flat = std.array_list.Managed(u32).init(alloc);
    errdefer faces_flat.deinit();
    var face_sizes = std.array_list.Managed(u32).init(alloc);
    errdefer face_sizes.deinit();

    var next: u32 = 0;
    for (mesh.tiles) |*t| {
        const hdr = t.header orelse continue;
        if (t.data_size == 0) continue;
        const pc: usize = @intCast(@max(hdr.poly_count, 0));
        var pi: usize = 0;
        while (pi < pc and pi < t.polys.len) : (pi += 1) {
            const poly = &t.polys[pi];
            const nv: usize = poly.vert_count;
            if (nv < 3) continue;
            // Собрать вершины грани с bounds-проверкой; пропустить грань при битом vert.
            var tmp: [recast.detour.common.VERTS_PER_POLYGON][3]f32 = undefined;
            var ok = true;
            var k: usize = 0;
            while (k < nv) : (k += 1) {
                const vi = @as(usize, poly.verts[k]) * 3;
                if (vi + 2 >= t.verts.len) {
                    ok = false;
                    break;
                }
                tmp[k] = .{ t.verts[vi], t.verts[vi + 1], t.verts[vi + 2] };
            }
            if (!ok) continue;
            k = 0;
            while (k < nv) : (k += 1) {
                try verts.append(tmp[k][0]);
                try verts.append(tmp[k][1]);
                try verts.append(tmp[k][2]);
                try faces_flat.append(next);
                next += 1;
            }
            try face_sizes.append(@intCast(nv));
        }
    }

    // toOwnedSlice по очереди с errdefer на уже-owned срезах (см. navTriangles):
    // защита от утечки если последующий toOwnedSlice падает (OOM).
    const verts_owned = try verts.toOwnedSlice();
    errdefer alloc.free(verts_owned);
    const faces_owned = try faces_flat.toOwnedSlice();
    errdefer alloc.free(faces_owned);
    const sizes_owned = try face_sizes.toOwnedSlice();
    return .{
        .verts = verts_owned,
        .faces_flat = faces_owned,
        .face_sizes = sizes_owned,
    };
}

// ===========================================================================
// 2D-полигоны XZ + цвета (area) для SVG
// ===========================================================================

pub const Polys2D = struct {
    polys_flat: []f32, // плоские пары x,z
    poly_sizes: []u32,
    colors: []u32, // 0x00RRGGBB
    bmin2: [2]f32, // [xmin, zmin]
    bmax2: [2]f32, // [xmax, zmax]

    pub fn deinit(self: *Polys2D, alloc: std.mem.Allocator) void {
        alloc.free(self.polys_flat);
        alloc.free(self.poly_sizes);
        alloc.free(self.colors);
        self.* = undefined;
    }
};

/// Извлечь r,g,b из area-реестра и упаковать в 0x00RRGGBB (формат export_svg).
/// Неизвестная area -> красный (как upstream areaToCol).
fn areaRgb(area: u8) u32 {
    if (area_types.get(area)) |at| {
        return (@as(u32, at.r) << 16) | (@as(u32, at.g) << 8) | @as(u32, at.b);
    }
    return 0xFF0000;
}

/// Собрать 2D top-down (XZ) полигоны навмеша + цвет area для SVG. bmin2/bmax2 —
/// фактический XZ-bbox пройденных вершин (если полигонов нет — {0,0}/{0,0}).
pub fn navPolys2D(alloc: std.mem.Allocator, mesh: *const dt.NavMesh) !Polys2D {
    var polys_flat = std.array_list.Managed(f32).init(alloc);
    errdefer polys_flat.deinit();
    var poly_sizes = std.array_list.Managed(u32).init(alloc);
    errdefer poly_sizes.deinit();
    var colors = std.array_list.Managed(u32).init(alloc);
    errdefer colors.deinit();

    var has_any = false;
    var xmin: f32 = 0;
    var zmin: f32 = 0;
    var xmax: f32 = 0;
    var zmax: f32 = 0;

    for (mesh.tiles) |*t| {
        const hdr = t.header orelse continue;
        if (t.data_size == 0) continue;
        const pc: usize = @intCast(@max(hdr.poly_count, 0));
        var pi: usize = 0;
        while (pi < pc and pi < t.polys.len) : (pi += 1) {
            const poly = &t.polys[pi];
            const nv: usize = poly.vert_count;
            if (nv < 3) continue;
            var tmp: [recast.detour.common.VERTS_PER_POLYGON][2]f32 = undefined;
            var ok = true;
            var k: usize = 0;
            while (k < nv) : (k += 1) {
                const vi = @as(usize, poly.verts[k]) * 3;
                if (vi + 2 >= t.verts.len) {
                    ok = false;
                    break;
                }
                tmp[k] = .{ t.verts[vi], t.verts[vi + 2] }; // x, z
            }
            if (!ok) continue;
            k = 0;
            while (k < nv) : (k += 1) {
                const x = tmp[k][0];
                const z = tmp[k][1];
                try polys_flat.append(x);
                try polys_flat.append(z);
                if (!has_any) {
                    xmin = x;
                    xmax = x;
                    zmin = z;
                    zmax = z;
                    has_any = true;
                } else {
                    xmin = @min(xmin, x);
                    xmax = @max(xmax, x);
                    zmin = @min(zmin, z);
                    zmax = @max(zmax, z);
                }
            }
            try poly_sizes.append(@intCast(nv));
            try colors.append(areaRgb(poly.getArea()));
        }
    }

    // toOwnedSlice по очереди с errdefer на уже-owned срезах (см. navTriangles):
    // защита от утечки если последующий toOwnedSlice падает (OOM).
    const polys_owned = try polys_flat.toOwnedSlice();
    errdefer alloc.free(polys_owned);
    const sizes_owned = try poly_sizes.toOwnedSlice();
    errdefer alloc.free(sizes_owned);
    const colors_owned = try colors.toOwnedSlice();
    return .{
        .polys_flat = polys_owned,
        .poly_sizes = sizes_owned,
        .colors = colors_owned,
        .bmin2 = .{ xmin, zmin },
        .bmax2 = .{ xmax, zmax },
    };
}
