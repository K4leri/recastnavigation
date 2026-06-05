//! headless_query — безоконный исполнитель navmesh-запросов (cluster H / P0).
//!
//! По готовому навмешу + NavMeshQuery выполняет массив QuerySpec и возвращает
//! заполненные export_query.QueryRecord (owned). Логика 1-в-1 с recalc() из
//! tool_navmesh_tester.zig: findNearestPoly(start/end, half_extents) -> запрос
//! нужного типа -> заполнение записи (status/npolys/nwaypoints/path_len/corners/
//! path/flags). GL/UI здесь нет — только Detour-запросы.
//!
//! Поддержанные типы (QuerySpec.type):
//!   "findPath"          — коридор полигонов (npolys, path[]); path_len по центрам.
//!   "findStraightPath"  — string-pull (corners[], nwaypoints); path_len по corners.
//!   "raycast"           — луч start->end; path_len = t-параметр (<=1 hit, >1 clear).
//!   "findNearestPoly"   — только snap старта; npolys=1 если найден.
//!   "findDistanceToWall"— дистанция до ближайшей стены; path_len = dist.

const std = @import("std");
const recast = @import("recast-nav");
const export_query = @import("../io/export_query.zig");
const io_util = @import("../io_util.zig");

const dt = recast.detour;

const MAX_POLYS = 256;

/// Один запрос для headless-исполнителя. start/end в мировых координатах.
/// include/exclude — маски poly-flags (как QueryFilter). half_extents — радиус
/// поиска для findNearestPoly (по умолчанию upstream {2,4,2}).
pub const QuerySpec = struct {
    type: []const u8,
    start: [3]f32,
    end: [3]f32 = .{ 0, 0, 0 },
    include: u16 = 0xffff,
    exclude: u16 = 0,
    half_extents: [3]f32 = .{ 2, 4, 2 },
};

/// 3D-расстояние между двумя точками.
fn dist3(a: [3]f32, b: [3]f32) f32 {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    const dz = a[2] - b[2];
    return @sqrt(dx * dx + dy * dy + dz * dz);
}

/// Центр полигона (среднее вершин) — порт getPolyCenter из tool_navmesh_tester.
fn polyCenter(nav: *const dt.NavMesh, ref: dt.PolyRef) [3]f32 {
    var c = [3]f32{ 0, 0, 0 };
    const r = nav.getTileAndPolyByRef(ref) catch return c;
    const nv = r.poly.vert_count;
    if (nv == 0) return c;
    for (0..nv) |i| {
        const vi = @as(usize, r.poly.verts[i]) * 3;
        c[0] += r.tile.verts[vi];
        c[1] += r.tile.verts[vi + 1];
        c[2] += r.tile.verts[vi + 2];
    }
    const s = 1.0 / @as(f32, @floatFromInt(nv));
    c[0] *= s;
    c[1] *= s;
    c[2] *= s;
    return c;
}

/// Текстовый статус из dt.Status (для QueryRecord.status).
fn statusStr(st: dt.Status) []const u8 {
    if (st.failure) return "failed";
    if (st.in_progress) return "in_progress";
    if (st.success) return if (st.partial_result) "partial" else "ok";
    return "invalid";
}

/// Выполнить все `specs` и вернуть owned-массив QueryRecord. Освобождать через
/// freeRecords(gpa, records). Каждая запись владеет id/kind/corners/path (heap).
pub fn runQueries(
    gpa: std.mem.Allocator,
    query: *dt.NavMeshQuery,
    nav: *const dt.NavMesh,
    specs: []const QuerySpec,
) ![]export_query.QueryRecord {
    var out = std.array_list.Managed(export_query.QueryRecord).init(gpa);
    errdefer {
        for (out.items) |r| freeRecord(gpa, r);
        out.deinit();
    }

    for (specs, 0..) |spec, idx| {
        const rec = try runOne(gpa, query, nav, spec, idx);
        try out.append(rec);
    }
    return out.toOwnedSlice();
}

/// Освободить массив, полученный из runQueries.
pub fn freeRecords(gpa: std.mem.Allocator, records: []export_query.QueryRecord) void {
    for (records) |r| freeRecord(gpa, r);
    gpa.free(records);
}

fn freeRecord(gpa: std.mem.Allocator, r: export_query.QueryRecord) void {
    gpa.free(r.id);
    gpa.free(r.kind);
    if (r.corners.len != 0) gpa.free(r.corners);
    if (r.path.len != 0) gpa.free(r.path);
}

fn runOne(
    gpa: std.mem.Allocator,
    q: *dt.NavMeshQuery,
    nav: *const dt.NavMesh,
    spec: QuerySpec,
    idx: usize,
) !export_query.QueryRecord {
    var filter = dt.QueryFilter.init();
    filter.setIncludeFlags(spec.include);
    filter.setExcludeFlags(spec.exclude);

    const id = try std.fmt.allocPrint(gpa, "Q{d}", .{idx});
    errdefer gpa.free(id);
    const kind = try gpa.dupe(u8, spec.type);
    errdefer gpa.free(kind);

    // База записи; corners/path заполняются ниже по типу.
    var rec = export_query.QueryRecord{
        .id = id,
        .kind = kind,
        .start = spec.start,
        .end = spec.end,
        .status = "invalid",
        .path_len = 0,
        .npolys = 0,
        .nwaypoints = 0,
        .ms = 0,
        .include_flags = spec.include,
        .exclude_flags = spec.exclude,
        .corners = &[_][3]f32{},
        .path = &[_]u32{},
    };

    // snap старта/конца на ближайший полигон (как recalc).
    var start_ref: dt.PolyRef = 0;
    var end_ref: dt.PolyRef = 0;
    var snapped: [3]f32 = undefined;
    _ = q.findNearestPoly(&spec.start, &spec.half_extents, &filter, &start_ref, &snapped) catch {};
    _ = q.findNearestPoly(&spec.end, &spec.half_extents, &filter, &end_ref, &snapped) catch {};

    var timer = io_util.PerfTimer.start();

    if (std.mem.eql(u8, spec.type, "findNearestPoly")) {
        if (start_ref != 0) {
            rec.status = "ok";
            rec.npolys = 1;
            const path = try gpa.alloc(u32, 1);
            path[0] = @intCast(start_ref);
            rec.path = path;
        } else {
            rec.status = "failed";
        }
    } else if (std.mem.eql(u8, spec.type, "findDistanceToWall")) {
        if (start_ref != 0) {
            var dist: f32 = 0;
            var hit_pos: [3]f32 = .{ 0, 0, 0 };
            var hit_normal: [3]f32 = .{ 0, 0, 0 };
            const st = q.findDistanceToWall(start_ref, &spec.start, 100.0, &filter, &dist, &hit_pos, &hit_normal) catch dt.Status.fail();
            rec.status = statusStr(st);
            rec.path_len = dist;
            // hit_pos как единственный "corner" — осмысленный вывод точки на стене.
            const corners = try gpa.alloc([3]f32, 1);
            corners[0] = hit_pos;
            rec.corners = corners;
            rec.nwaypoints = 1;
        } else {
            rec.status = "failed";
        }
    } else if (std.mem.eql(u8, spec.type, "raycast")) {
        if (start_ref != 0) {
            var path_buf: [MAX_POLYS]dt.PolyRef = undefined;
            var hit = dt.RaycastHit.init(path_buf[0..]);
            const st = q.raycast(start_ref, &spec.start, &spec.end, &filter, 0, &hit, 0) catch dt.Status.fail();
            rec.status = statusStr(st);
            // t>1 => луч дошёл до конца без стены; t<=1 => точка попадания.
            rec.path_len = if (std.math.isFinite(hit.t)) @min(hit.t, 1.0) else 1.0;
            rec.npolys = @intCast(hit.path_count);
            if (hit.path_count != 0) {
                const path = try gpa.alloc(u32, hit.path_count);
                for (0..hit.path_count) |i| path[i] = @intCast(hit.path[i]);
                rec.path = path;
            }
        } else {
            rec.status = "failed";
        }
    } else if (std.mem.eql(u8, spec.type, "findPath") or std.mem.eql(u8, spec.type, "findStraightPath")) {
        if (start_ref != 0 and end_ref != 0) {
            var polys: [MAX_POLYS]dt.PolyRef = undefined;
            var n: usize = 0;
            const st = blk: {
                q.findPath(start_ref, end_ref, &spec.start, &spec.end, &filter, polys[0..], &n) catch break :blk dt.Status.fail();
                break :blk dt.Status.ok();
            };
            _ = st;
            rec.npolys = @intCast(n);
            if (n > 0) {
                const path = try gpa.alloc(u32, n);
                for (0..n) |i| path[i] = @intCast(polys[i]);
                rec.path = path;

                // partial, если коридор не достиг конечного полигона.
                const reached_end = polys[n - 1] == end_ref;
                rec.status = if (reached_end) "ok" else "partial";

                if (std.mem.eql(u8, spec.type, "findStraightPath")) {
                    var straight: [MAX_POLYS * 3]f32 = undefined;
                    var ns: usize = 0;
                    _ = q.findStraightPath(&spec.start, &spec.end, polys[0..n], straight[0..], null, null, &ns, 0) catch {};
                    rec.nwaypoints = @intCast(ns);
                    if (ns > 0) {
                        const corners = try gpa.alloc([3]f32, ns);
                        var plen: f32 = 0;
                        for (0..ns) |i| {
                            corners[i] = .{ straight[i * 3], straight[i * 3 + 1], straight[i * 3 + 2] };
                            if (i > 0) plen += dist3(corners[i - 1], corners[i]);
                        }
                        rec.corners = corners;
                        rec.path_len = plen;
                    }
                } else {
                    // findPath: длина по центрам полигонов коридора.
                    var plen: f32 = 0;
                    var prev = polyCenter(nav, polys[0]);
                    for (1..n) |i| {
                        const cur = polyCenter(nav, polys[i]);
                        plen += dist3(prev, cur);
                        prev = cur;
                    }
                    rec.path_len = plen;
                }
            } else {
                rec.status = "failed";
            }
        } else {
            rec.status = "failed";
        }
    } else {
        // неизвестный тип — пометить invalid, не падать.
        rec.status = "invalid";
    }

    rec.ms = timer.readMs();

    return rec;
}
