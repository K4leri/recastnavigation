//! navmesh_walk — общий READ-ONLY обход живого dt.NavMesh для demo-потребителей.
//!
//! Дедуп: до этого модуля каждый потребитель (nav_export, poly_visit, diag/*,
//! tester drawPolySafe, headless_query, main.zig) нёс СВОЮ копию одного и того же
//! обхода тайлов/полигонов, своё вычисление центроида и свой bounds-safe резолв
//! вершины detail-треугольника. Семантика этих копий БАЙТ-В-БАЙТ идентична —
//! здесь она лифтнута в чистые free-fn ОДИН раз.
//!
//! Принципы (строго):
//!   - faithful src/* НЕ трогаем; это только обвязка над публичным API NavMesh.
//!   - Всё bounds-safe ровно как эталон drawPolySafe / nav_export.detailVert:
//!     каждый доступ к detail_tris/detail_verts/poly.verts/tile.verts проверяется,
//!     битый/устаревший ref НИКОГДА не выходит за границы.
//!   - Фильтрация (offmesh-skip, poly_count vs links, header==null) ОТЛИЧАЕТСЯ у
//!     потребителей. forEachDrawablePoly даёт callback (tile, poly, poly_index) и
//!     НЕ зашивает фильтр — решение остаётся у потребителя.
//!   - Специфический per-consumer обход (Dijkstra-relax в reachability, gated-by-
//!     passFilter BFS в diagnose, cycle-guarded link-walk в verify/lint, faithful
//!     floodNavmesh в tool_prune) НЕ объединяется — он не идентичен.

const std = @import("std");
const recast = @import("recast-nav");

const dt = recast.detour;
const MeshTile = dt.MeshTile;
const Poly = dt.Poly;
const PolyDetail = dt.PolyDetail;
const NavMesh = dt.NavMesh;
const PolyRef = dt.PolyRef;

// ===========================================================================
// Centroid
// ===========================================================================

/// Centroid = среднее world-space позиций outer-ring вершин полигона
/// (tile.verts по poly.verts[0..vert_count]). Пустой поли (vert_count==0) -> {0,0,0}.
///
/// Каноничная форма: 1-в-1 с filter_compare.polyCentroid / reachability.polyCentroid /
/// tester.getPolyCenter / headless.polyCenter (тело идентично; bad-ref политика —
/// у обёрток ниже). БЕЗ bounds-check на verts (как все эти копии: poly у валидного
/// тайла всегда консистентен; poly_inspect, которому нужен ранний выход на битых
/// данных, держит свой guarded-вариант локально).
pub fn polyCentroid(tile: *const MeshTile, poly: *const Poly) [3]f32 {
    var c = [3]f32{ 0, 0, 0 };
    const nv: usize = poly.vert_count;
    if (nv == 0) return c;
    for (0..nv) |i| {
        const vi = @as(usize, poly.verts[i]) * 3;
        c[0] += tile.verts[vi];
        c[1] += tile.verts[vi + 1];
        c[2] += tile.verts[vi + 2];
    }
    const s = 1.0 / @as(f32, @floatFromInt(nv));
    c[0] *= s;
    c[1] *= s;
    c[2] *= s;
    return c;
}

// ===========================================================================
// Ref resolution
// ===========================================================================

/// BULLETPROOF резолв (tile, poly) по ref — обёртка над getTileAndPolyByRef с
/// ДОПОЛНИТЕЛЬНОЙ проверкой `decoded.tile < tiles.len` (эталон drawPolySafe).
///
/// Почему недостаточно одного getTileAndPolyByRef: он проверяет `decoded.tile <
/// max_tiles` и затем индексирует `tiles[decoded.tile]`. В реальной истории
/// наблюдалась паника `tiles[150] len 149`, где `decoded.tile < max_tiles`, но
/// `>= tiles.len` (поле max_tiles рассинхронилось со срезом tiles после
/// corrupt/stale-чтения). Сначала валидируем против ФАКТИЧЕСКОГО среза, потом
/// зовём faithful-геттер (он доделает salt/header/poly_count). ref==0 -> null.
pub fn tileAndPoly(nav: *const NavMesh, ref: PolyRef) ?struct { tile: *MeshTile, poly: *Poly } {
    if (ref == 0) return null;
    const d = nav.decodePolyId(ref);
    if (@as(usize, d.tile) >= nav.tiles.len) return null;
    const tp = nav.getTileAndPolyByRef(ref) catch return null;
    return .{ .tile = tp.tile, .poly = tp.poly };
}

/// Centroid по ref: tileAndPoly + polyCentroid. null при битом/нулевом ref.
pub fn polyCentroidByRef(nav: *const NavMesh, ref: PolyRef) ?[3]f32 {
    const tp = tileAndPoly(nav, ref) orelse return null;
    return polyCentroid(tp.tile, tp.poly);
}

// ===========================================================================
// Detail-mesh vertex resolution
// ===========================================================================

/// Резолв world-space координаты вершины `k`-го угла detail-треугольника:
///   k < vert_count  -> outer-ring poly-вершина (tile.verts по poly.verts[k]);
///   k >= vert_count -> detail-вершина (tile.detail_verts, смещение pd.vert_base
///                      + (k - vert_count)).
/// Каждый доступ bounds-checked; индекс вне границ -> null (битый ref не OOB).
/// `vert_count` = poly.vert_count. ЛИФТ из nav_export.detailVert / drawPolySafe
/// (тело идентично обоим).
pub fn detailVert(
    tile: *const MeshTile,
    poly: *const Poly,
    pd: *const PolyDetail,
    vert_count: usize,
    k: u8,
) ?[3]f32 {
    if (k < vert_count) {
        if (@as(usize, k) >= poly.verts.len) return null;
        const v_idx = @as(usize, poly.verts[k]) * 3;
        if (v_idx + 2 >= tile.verts.len) return null;
        return .{ tile.verts[v_idx], tile.verts[v_idx + 1], tile.verts[v_idx + 2] };
    } else {
        const d_idx = (@as(usize, pd.vert_base) + (@as(usize, k) - vert_count)) * 3;
        if (d_idx + 2 >= tile.detail_verts.len) return null;
        return .{ tile.detail_verts[d_idx], tile.detail_verts[d_idx + 1], tile.detail_verts[d_idx + 2] };
    }
}

/// Обход detail-треугольников полигона с bounds-safe резолвом всех трёх вершин.
/// Для каждого ВАЛИДНОГО треугольника (все три вершины разрешились) зовёт
/// `cb(ctx, p0, p1, p2)` где p* = [3]f32 world-space. Треугольник с битой
/// вершиной ПРОПУСКАЕТСЯ (как nav_export.navTriangles: `if (!ok) continue`).
///
/// Поведение 1-в-1 с эталонными fill/triangulation-проходами:
///   - tri-range guard: `t_idx + 3 >= tile.detail_tris.len` -> break (стоп поли,
///     как navTriangles/drawPolySafe).
///   - `vert_count` берём из poly.vert_count; pd — detail_meshes[poly_index].
pub fn forEachDetailTri(
    tile: *const MeshTile,
    poly: *const Poly,
    pd: *const PolyDetail,
    ctx: anytype,
    comptime cb: fn (@TypeOf(ctx), p0: [3]f32, p1: [3]f32, p2: [3]f32) void,
) void {
    const vc: usize = poly.vert_count;
    var ti: usize = 0;
    while (ti < @as(usize, pd.tri_count)) : (ti += 1) {
        const t_idx = (@as(usize, pd.tri_base) + ti) * 4;
        if (t_idx + 3 >= tile.detail_tris.len) break;
        const tri = tile.detail_tris[t_idx .. t_idx + 4];
        var p: [3][3]f32 = undefined;
        var ok = true;
        for (0..3) |kk| {
            if (detailVert(tile, poly, pd, vc, tri[kk])) |v| {
                p[kk] = v;
            } else {
                ok = false;
                break;
            }
        }
        if (!ok) continue;
        cb(ctx, p[0], p[1], p[2]);
    }
}

// ===========================================================================
// Tile / poly traversal
// ===========================================================================

/// Обход всех тайлов навмеша -> валидные тайлы (header != null, data_size != 0) ->
/// полигоны [0..poly_count). Для каждого полигона зовёт `cb(ctx, tile, poly,
/// poly_index)`. Фильтр (offmesh-skip и т.п.) НЕ зашит — callback решает сам.
///
/// Итерация совпадает с эталоном nav_export (по mesh.tiles, header orelse continue,
/// data_size==0 skip, `pc = max(poly_count,0)`, `pi < pc and pi < t.polys.len`).
/// ВНИМАНИЕ про data_size: потребители, итерирующие по `mesh.max_tiles` БЕЗ
/// проверки data_size (poly_visit, components, main.zig), не должны мигрировать на
/// этот обход слепо — у них чуть другой набор тайлов (хотя для построенного меша
/// валидные тайлы совпадают). Используется там, где эталон — nav_export.
pub fn forEachDrawablePoly(
    mesh: *const NavMesh,
    ctx: anytype,
    comptime cb: fn (@TypeOf(ctx), tile: *const MeshTile, poly: *const Poly, poly_index: usize) void,
) void {
    for (mesh.tiles) |*t| {
        const hdr = t.header orelse continue;
        if (t.data_size == 0) continue;
        const pc: usize = @intCast(@max(hdr.poly_count, 0));
        var pi: usize = 0;
        while (pi < pc and pi < t.polys.len) : (pi += 1) {
            cb(ctx, t, &t.polys[pi], pi);
        }
    }
}

// ===========================================================================
// Tests (pure helpers; full traversal needs a real NavMesh -> owner-verified)
// ===========================================================================
const testing = std.testing;

test "polyCentroid: empty poly -> origin" {
    // vert_count==0 short-circuits before any verts access.
    var tile = MeshTile.init(testing.allocator);
    var poly = Poly.init();
    poly.vert_count = 0;
    try testing.expectEqual([3]f32{ 0, 0, 0 }, polyCentroid(&tile, &poly));
}

test "polyCentroid: average of three verts" {
    var tile = MeshTile.init(testing.allocator);
    var verts = [_]f32{ 0, 0, 0, 3, 0, 0, 0, 0, 3 }; // 3 verts
    tile.verts = &verts;
    var poly = Poly.init();
    poly.verts[0] = 0;
    poly.verts[1] = 1;
    poly.verts[2] = 2;
    poly.vert_count = 3;
    const c = polyCentroid(&tile, &poly);
    try testing.expectApproxEqAbs(@as(f32, 1.0), c[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), c[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), c[2], 1e-6);
}

test "tileAndPoly / polyCentroidByRef: ref==0 -> null" {
    const nav: *const NavMesh = undefined; // ref==0 short-circuits before deref
    try testing.expectEqual(@as(?[3]f32, null), polyCentroidByRef(nav, 0));
}

test "detailVert: outer-ring index resolves from tile.verts" {
    var tile = MeshTile.init(testing.allocator);
    var verts = [_]f32{ 7, 8, 9, 1, 2, 3 };
    tile.verts = &verts;
    var dverts = [_]f32{0} ** 3;
    tile.detail_verts = &dverts;
    var poly = Poly.init();
    poly.verts[0] = 1;
    poly.verts[1] = 0;
    poly.vert_count = 2;
    var pd = PolyDetail.init();
    // k=0 < vc=2 -> poly.verts[0]=1 -> tile.verts[3..6] = {1,2,3}
    const v = detailVert(&tile, &poly, &pd, 2, 0);
    try testing.expect(v != null);
    try testing.expectEqual([3]f32{ 1, 2, 3 }, v.?);
}

test "detailVert: out-of-range detail index -> null" {
    var tile = MeshTile.init(testing.allocator);
    var verts = [_]f32{0} ** 3;
    tile.verts = &verts;
    var dverts = [_]f32{ 0, 0, 0 }; // only 1 detail vert
    tile.detail_verts = &dverts;
    var poly = Poly.init();
    poly.vert_count = 0;
    var pd = PolyDetail.init();
    pd.vert_base = 0;
    // k=5 >= vc=0 -> detail idx (0 + 5)*3 = 15, +2 = 17 >= 3 -> null
    try testing.expectEqual(@as(?[3]f32, null), detailVert(&tile, &poly, &pd, 0, 5));
}
