//! PartitionedMesh — порт RecastDemo/Source/PartitionedMesh.cpp (бывш. ChunkyTriMesh).
//! k/d-дерево по XZ-границам треугольников: лист хранит <= tris_per_chunk
//! треугольников (копии индексных троек, переупорядоченные). Тайловые сэмплы
//! растеризуют только чанки, пересекающие тайл; raycast — только чанки вдоль луча.
//!
//! Отличия от C++ (поведение результата не меняют):
//! - PR recastnavigation#815 (std::vector по значению в рекурсивном subdivide ->
//!   O(n^2) копий) в Zig невозможен: слайсы и так ptr+len.
//! - qsort-компаратор C++ `(int)(a.bmin - b.bmin)` (усечение разности до int) не
//!   образует strict weak ordering (0.0 == 0.6 == 1.2, но 0.0 < 1.2) — для
//!   std.sort.pdq это UB, поэтому сравниваем float напрямую. Разбиение на чанки
//!   может отличаться порядком, но итоговый navmesh/raycast идентичны: чанк лишь
//!   группирует треугольники, выбор "какие растеризовать в тайл" перекрывается
//!   клиппингом по heightfield, а raycast перебирает все чанки, пересекающие луч.

const std = @import("std");

const IndexedBounds = struct {
    bmin: [2]f32,
    bmax: [2]f32,
    index: i32,
};

/// Суммарный экстент bounds в диапазоне [start, end).
fn calcTotalBounds(bounds: []const IndexedBounds, start: usize, end: usize, out_bmin: *[2]f32, out_bmax: *[2]f32) void {
    out_bmin.* = bounds[start].bmin;
    out_bmax.* = bounds[start].bmax;
    for (bounds[start + 1 .. end]) |it| {
        out_bmin[0] = @min(it.bmin[0], out_bmin[0]);
        out_bmin[1] = @min(it.bmin[1], out_bmin[1]);
        out_bmax[0] = @max(it.bmax[0], out_bmax[0]);
        out_bmax[1] = @max(it.bmax[1], out_bmax[1]);
    }
}

fn lessThanMinAxis(axis: usize, a: IndexedBounds, b: IndexedBounds) bool {
    return a.bmin[axis] < b.bmin[axis];
}

fn checkOverlapRect(amin: [2]f32, amax: [2]f32, bmin: [2]f32, bmax: [2]f32) bool {
    return amin[0] <= bmax[0] and amax[0] >= bmin[0] and amin[1] <= bmax[1] and amax[1] >= bmin[1];
}

fn checkOverlapSegment(p: [2]f32, q: [2]f32, bmin: [2]f32, bmax: [2]f32) bool {
    const EPSILON: f32 = 1e-6;
    var tmin: f32 = 0;
    var tmax: f32 = 1;
    const d = [2]f32{ q[0] - p[0], q[1] - p[1] };

    for (0..2) |i| {
        if (@abs(d[i]) < EPSILON) {
            // Луч параллелен слэбу: нет попадания, если начало вне слэба.
            if (p[i] < bmin[i] or p[i] > bmax[i]) return false;
        } else {
            const ood = 1.0 / d[i];
            var t1 = (bmin[i] - p[i]) * ood;
            var t2 = (bmax[i] - p[i]) * ood;
            if (t1 > t2) std.mem.swap(f32, &t1, &t2);
            if (t1 > tmin) tmin = t1;
            if (t2 < tmax) tmax = t2;
            if (tmin > tmax) return false;
        }
    }
    return true;
}

/// Пространственно-разбитый меш (k/d-дерево), каждый узел содержит
/// не более tris_per_chunk треугольников.
pub const PartitionedMesh = struct {
    pub const Node = struct {
        // XZ-границы
        bmin: [2]f32 = .{ 0, 0 },
        bmax: [2]f32 = .{ 0, 0 },
        /// >= 0 — лист (база в tris); < 0 — escape-смещение для обхода.
        tri_index: i32 = 0,
        num_tris: i32 = 0,
    };

    alloc: std.mem.Allocator,
    nodes: []Node = &.{},
    nnodes: usize = 0,
    /// Переупорядоченные копии индексных троек (i0,i1,i2 на треугольник).
    tris: []i32 = &.{},
    max_tris_per_chunk: i32 = 0,

    pub fn init(alloc: std.mem.Allocator) PartitionedMesh {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *PartitionedMesh) void {
        self.alloc.free(self.nodes);
        self.alloc.free(self.tris);
        self.nodes = &.{};
        self.tris = &.{};
        self.nnodes = 0;
        self.max_tris_per_chunk = 0;
    }

    /// Аналог PartitionedMesh::PartitionMesh. Перестраивает дерево с нуля.
    pub fn partitionMesh(self: *PartitionedMesh, verts: []const f32, in_tris: []const i32, tris_per_chunk: usize) !void {
        self.deinit();
        const num_tris = in_tris.len / 3;
        if (num_tris == 0) return;

        // XZ-границы каждого треугольника.
        const tri_bounds = try self.alloc.alloc(IndexedBounds, num_tris);
        defer self.alloc.free(tri_bounds);
        for (tri_bounds, 0..) |*bound, tri_index| {
            const tri = in_tris[tri_index * 3 ..][0..3];
            bound.index = @intCast(tri_index);
            const v0: usize = @intCast(tri[0]);
            bound.bmin = .{ verts[v0 * 3 + 0], verts[v0 * 3 + 2] };
            bound.bmax = bound.bmin;
            for (tri[1..3]) |vi| {
                const v: usize = @intCast(vi);
                const x = verts[v * 3 + 0];
                bound.bmin[0] = @min(x, bound.bmin[0]);
                bound.bmax[0] = @max(x, bound.bmax[0]);
                const z = verts[v * 3 + 2];
                bound.bmin[1] = @min(z, bound.bmin[1]);
                bound.bmax[1] = @max(z, bound.bmax[1]);
            }
        }

        // Дерево: numChunks*4 узлов, как в оригинале.
        const num_chunks: usize = (num_tris + tris_per_chunk - 1) / tris_per_chunk;
        self.nodes = try self.alloc.alloc(Node, num_chunks * 4);
        @memset(self.nodes, .{});
        self.tris = try self.alloc.alloc(i32, num_tris * 3);
        var cur_tri: usize = 0;
        var cur_node: usize = 0;
        subdivide(tri_bounds, 0, num_tris, tris_per_chunk, &cur_node, self.nodes, &cur_tri, self.tris, in_tris);
        self.nnodes = cur_node;

        // Максимум треугольников на чанк.
        self.max_tris_per_chunk = 0;
        for (self.nodes[0..self.nnodes]) |*node| {
            if (node.tri_index < 0) continue; // не лист
            self.max_tris_per_chunk = @max(self.max_tris_per_chunk, node.num_tris);
        }
    }

    fn subdivide(
        tri_bounds: []IndexedBounds,
        imin: usize,
        imax: usize,
        tris_per_chunk: usize,
        cur_node: *usize,
        nodes: []Node,
        cur_tri: *usize,
        out_tris: []i32,
        in_tris: []const i32,
    ) void {
        const num_in_range = imax - imin;
        const icur = cur_node.*;

        if (cur_node.* >= nodes.len) return;

        const node = &nodes[cur_node.*];
        cur_node.* += 1;

        if (num_in_range <= tris_per_chunk) { // лист
            calcTotalBounds(tri_bounds, imin, imax, &node.bmin, &node.bmax);

            // Копируем треугольники.
            node.tri_index = @intCast(cur_tri.*);
            node.num_tris = @intCast(num_in_range);
            for (tri_bounds[imin..imax]) |tb| {
                const src = in_tris[@as(usize, @intCast(tb.index)) * 3 ..][0..3];
                out_tris[cur_tri.* * 3 ..][0..3].* = src.*;
                cur_tri.* += 1;
            }
        } else {
            // Разбиение: сортировка вдоль длинной оси.
            calcTotalBounds(tri_bounds, imin, imax, &node.bmin, &node.bmax);
            const x_length = node.bmax[0] - node.bmin[0];
            const y_length = node.bmax[1] - node.bmin[1];
            const axis: usize = if (x_length >= y_length) 0 else 1;
            std.sort.pdq(IndexedBounds, tri_bounds[imin..imax], axis, lessThanMinAxis);

            const isplit = imin + num_in_range / 2;
            subdivide(tri_bounds, imin, isplit, tris_per_chunk, cur_node, nodes, cur_tri, out_tris, in_tris);
            subdivide(tri_bounds, isplit, imax, tris_per_chunk, cur_node, nodes, cur_tri, out_tris, in_tris);

            // Отрицательный индекс = escape.
            node.tri_index = @as(i32, @intCast(icur)) - @as(i32, @intCast(cur_node.*));
        }
    }

    /// Индексы листов, пересекающих прямоугольник (XZ).
    pub fn nodesOverlappingRect(self: *const PartitionedMesh, bmin: [2]f32, bmax: [2]f32, out_nodes: *std.array_list.Managed(usize)) !void {
        try self.traverse(out_nodes, bmin, bmax, checkOverlapRect);
    }

    /// Индексы листов, пересекающих отрезок (XZ).
    pub fn nodesOverlappingSegment(self: *const PartitionedMesh, p: [2]f32, q: [2]f32, out_nodes: *std.array_list.Managed(usize)) !void {
        try self.traverse(out_nodes, p, q, checkOverlapSegment);
    }

    fn traverse(
        self: *const PartitionedMesh,
        out_nodes: *std.array_list.Managed(usize),
        a: [2]f32,
        b: [2]f32,
        comptime overlapFn: fn ([2]f32, [2]f32, [2]f32, [2]f32) bool,
    ) !void {
        var node_index: usize = 0;
        while (node_index < self.nnodes) {
            const node = &self.nodes[node_index];
            const overlap = overlapFn(a, b, node.bmin, node.bmax);
            const is_leaf = node.tri_index >= 0;

            if (is_leaf and overlap) try out_nodes.append(node_index);

            if (overlap or is_leaf) {
                node_index += 1;
            } else {
                // escape-индекс
                node_index += @intCast(-node.tri_index);
            }
        }
    }

    /// Индексные тройки листа `node_index` (слайс в переупорядоченном tris).
    pub fn nodeTris(self: *const PartitionedMesh, node_index: usize) []const i32 {
        const node = &self.nodes[node_index];
        const base: usize = @intCast(node.tri_index);
        const n: usize = @intCast(node.num_tris);
        return self.tris[base * 3 ..][0 .. n * 3];
    }
};

// --- tests ---

const testing = std.testing;

/// Сетка quads (nx x nz) на y=0, шаг 1: верш. (nx+1)*(nz+1), 2 tri на ячейку.
fn buildGrid(alloc: std.mem.Allocator, nx: usize, nz: usize) !struct { verts: []f32, tris: []i32 } {
    const verts = try alloc.alloc(f32, (nx + 1) * (nz + 1) * 3);
    for (0..nz + 1) |z| {
        for (0..nx + 1) |x| {
            const i = (z * (nx + 1) + x) * 3;
            verts[i] = @floatFromInt(x);
            verts[i + 1] = 0;
            verts[i + 2] = @floatFromInt(z);
        }
    }
    const tris = try alloc.alloc(i32, nx * nz * 6);
    for (0..nz) |z| {
        for (0..nx) |x| {
            const v0: i32 = @intCast(z * (nx + 1) + x);
            const v1 = v0 + 1;
            const v2 = v0 + @as(i32, @intCast(nx + 1));
            const v3 = v2 + 1;
            const t = (z * nx + x) * 6;
            tris[t..][0..6].* = .{ v0, v2, v1, v1, v2, v3 };
        }
    }
    return .{ .verts = verts, .tris = tris };
}

test "partitionMesh: все треугольники сохранены ровно по одному разу" {
    const alloc = testing.allocator;
    const grid = try buildGrid(alloc, 16, 16);
    defer alloc.free(grid.verts);
    defer alloc.free(grid.tris);

    var pm = PartitionedMesh.init(alloc);
    defer pm.deinit();
    try pm.partitionMesh(grid.verts, grid.tris, 32);

    const num_tris = grid.tris.len / 3;
    try testing.expect(pm.nnodes > 1);
    try testing.expect(pm.max_tris_per_chunk > 0 and pm.max_tris_per_chunk <= 32);

    // Каждая исходная тройка встречается в переупорядоченном tris ровно один раз.
    const seen = try alloc.alloc(bool, num_tris);
    defer alloc.free(seen);
    @memset(seen, false);
    var leaf_total: usize = 0;
    for (0..pm.nnodes) |ni| {
        if (pm.nodes[ni].tri_index < 0) continue;
        const nt = pm.nodeTris(ni);
        leaf_total += nt.len / 3;
        var k: usize = 0;
        outer: while (k < nt.len) : (k += 3) {
            var t: usize = 0;
            while (t < grid.tris.len) : (t += 3) {
                if (!seen[t / 3] and grid.tris[t] == nt[k] and grid.tris[t + 1] == nt[k + 1] and grid.tris[t + 2] == nt[k + 2]) {
                    seen[t / 3] = true;
                    continue :outer;
                }
            }
            return error.TriangleNotFound;
        }
    }
    try testing.expectEqual(num_tris, leaf_total);
    for (seen) |s| try testing.expect(s);
}

test "nodesOverlappingRect: чанки покрывают все треугольники, пересекающие rect" {
    const alloc = testing.allocator;
    const grid = try buildGrid(alloc, 16, 16);
    defer alloc.free(grid.verts);
    defer alloc.free(grid.tris);

    var pm = PartitionedMesh.init(alloc);
    defer pm.deinit();
    try pm.partitionMesh(grid.verts, grid.tris, 8);

    const rmin = [2]f32{ 3.5, 3.5 };
    const rmax = [2]f32{ 7.5, 7.5 };
    var ids = std.array_list.Managed(usize).init(alloc);
    defer ids.deinit();
    try pm.nodesOverlappingRect(rmin, rmax, &ids);
    try testing.expect(ids.items.len > 0);

    // Brute force: каждый треугольник, чей XZ-bbox пересекает rect, обязан лежать
    // в одном из выбранных чанков (k/d-дерево не теряет кандидатов).
    var t: usize = 0;
    while (t < grid.tris.len) : (t += 3) {
        var tb_min = [2]f32{ std.math.floatMax(f32), std.math.floatMax(f32) };
        var tb_max = [2]f32{ -std.math.floatMax(f32), -std.math.floatMax(f32) };
        for (0..3) |c| {
            const v: usize = @intCast(grid.tris[t + c]);
            tb_min[0] = @min(tb_min[0], grid.verts[v * 3]);
            tb_max[0] = @max(tb_max[0], grid.verts[v * 3]);
            tb_min[1] = @min(tb_min[1], grid.verts[v * 3 + 2]);
            tb_max[1] = @max(tb_max[1], grid.verts[v * 3 + 2]);
        }
        if (!checkOverlapRect(rmin, rmax, tb_min, tb_max)) continue;

        var found = false;
        for (ids.items) |ni| {
            const nt = pm.nodeTris(ni);
            var k: usize = 0;
            while (k < nt.len) : (k += 3) {
                if (grid.tris[t] == nt[k] and grid.tris[t + 1] == nt[k + 1] and grid.tris[t + 2] == nt[k + 2]) {
                    found = true;
                    break;
                }
            }
            if (found) break;
        }
        try testing.expect(found);
    }
}

test "nodesOverlappingSegment: сегмент по диагонали находит чанки, мимо — нет" {
    const alloc = testing.allocator;
    const grid = try buildGrid(alloc, 16, 16);
    defer alloc.free(grid.verts);
    defer alloc.free(grid.tris);

    var pm = PartitionedMesh.init(alloc);
    defer pm.deinit();
    try pm.partitionMesh(grid.verts, grid.tris, 8);

    var ids = std.array_list.Managed(usize).init(alloc);
    defer ids.deinit();
    try pm.nodesOverlappingSegment(.{ 0.5, 0.5 }, .{ 15.5, 15.5 }, &ids);
    try testing.expect(ids.items.len > 0);

    ids.clearRetainingCapacity();
    try pm.nodesOverlappingSegment(.{ 100, 100 }, .{ 200, 200 }, &ids);
    try testing.expectEqual(@as(usize, 0), ids.items.len);
}

test "пустой меш и меш меньше одного чанка" {
    const alloc = testing.allocator;
    var pm = PartitionedMesh.init(alloc);
    defer pm.deinit();
    try pm.partitionMesh(&.{}, &.{}, 256);
    try testing.expectEqual(@as(usize, 0), pm.nnodes);

    // 1 треугольник < tris_per_chunk -> единственный лист-корень.
    const verts = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    const tris = [_]i32{ 0, 1, 2 };
    try pm.partitionMesh(&verts, &tris, 256);
    try testing.expectEqual(@as(usize, 1), pm.nnodes);
    try testing.expectEqual(@as(i32, 1), pm.nodes[0].num_tris);
    try testing.expectEqual(@as(i32, 1), pm.max_tris_per_chunk);
}
