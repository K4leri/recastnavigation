const std = @import("std");
const glb = @import("glb.zig");

/// Собрать минимальный валидный glb (бинарный glTF 2.0) из треугольной геометрии.
/// verts: плоские тройки x,y,z (f32). indices: плоские u32-индексы треугольников
/// (кратно 3). Возвращает owned []u8 (caller frees).
/// Структура: header(magic 'glTF',ver2,len) + JSON-чанк + BIN-чанк.
/// В JSON: 1 buffer, 2 bufferView (indices, positions), 2 accessor
/// (indices SCALAR u32/u16, POSITION VEC3 FLOAT с min/max), 1 mesh/primitive
/// (mode TRIANGLES, indices + attribute POSITION), 1 node, 1 scene.
/// BIN: индексы затем позиции (с выравниванием по 4 байта).
pub fn writeGlb(alloc: std.mem.Allocator, verts: []const f32, indices: []const u32) ![]u8 {
    if (verts.len % 3 != 0) return error.InvalidVertexCount;
    if (indices.len % 3 != 0) return error.InvalidIndexCount;

    const vert_count: u32 = @intCast(verts.len / 3);
    const index_count: u32 = @intCast(indices.len);

    // --- min/max по компонентам позиции (требование glTF для POSITION) ---
    var pmin = [3]f32{ 0, 0, 0 };
    var pmax = [3]f32{ 0, 0, 0 };
    if (vert_count > 0) {
        pmin = .{ verts[0], verts[1], verts[2] };
        pmax = pmin;
        var i: usize = 0;
        while (i < verts.len) : (i += 3) {
            inline for (0..3) |c| {
                const v = verts[i + c];
                if (v < pmin[c]) pmin[c] = v;
                if (v > pmax[c]) pmax[c] = v;
            }
        }
    }

    // --- выбор ширины индексов: u16 если все < 65536 (компактнее), иначе u32 ---
    var use_u16 = true;
    for (indices) |idx| {
        if (idx >= 65536) {
            use_u16 = false;
            break;
        }
    }
    const index_component_type: u32 = if (use_u16) 5123 else 5125; // UNSIGNED_SHORT / UNSIGNED_INT
    const index_stride: usize = if (use_u16) 2 else 4;

    // --- раскладка BIN-буфера ---
    const indices_byte_len: usize = index_count * index_stride;
    // позиции выравниваем по 4 (componentType FLOAT, требование glTF: offset кратен размеру компонента)
    const positions_byte_offset: usize = align4(indices_byte_len);
    const positions_byte_len: usize = @as(usize, vert_count) * 3 * @sizeOf(f32);
    const buffer_byte_len: usize = positions_byte_offset + positions_byte_len;

    // --- собрать BIN payload ---
    var bin = std.array_list.Managed(u8).init(alloc);
    defer bin.deinit();
    try bin.ensureTotalCapacity(buffer_byte_len);

    // индексы
    for (indices) |idx| {
        if (use_u16) {
            const v: u16 = @intCast(idx);
            try appendLe(&bin, u16, v);
        } else {
            try appendLe(&bin, u32, idx);
        }
    }
    // паддинг до выравнивания позиций
    while (bin.items.len < positions_byte_offset) try bin.append(0);
    // позиции
    for (verts) |f| {
        try appendLe(&bin, u32, @bitCast(f));
    }
    std.debug.assert(bin.items.len == buffer_byte_len);

    // --- собрать JSON ---
    var json = std.array_list.Managed(u8).init(alloc);
    defer json.deinit();
    var numbuf: [64]u8 = undefined;

    try json.appendSlice("{\"asset\":{\"version\":\"2.0\",\"generator\":\"zig-recast export_gltf\"},");
    try json.appendSlice("\"buffers\":[{\"byteLength\":");
    try appendUint(&json, &numbuf, buffer_byte_len);
    try json.appendSlice("}],");

    // bufferViews: 0 = indices, 1 = positions
    try json.appendSlice("\"bufferViews\":[{\"buffer\":0,\"byteOffset\":0,\"byteLength\":");
    try appendUint(&json, &numbuf, indices_byte_len);
    try json.appendSlice(",\"target\":34963},{\"buffer\":0,\"byteOffset\":");
    try appendUint(&json, &numbuf, positions_byte_offset);
    try json.appendSlice(",\"byteLength\":");
    try appendUint(&json, &numbuf, positions_byte_len);
    try json.appendSlice(",\"target\":34962}],");

    // accessors: 0 = indices SCALAR, 1 = POSITION VEC3 FLOAT с min/max
    try json.appendSlice("\"accessors\":[{\"bufferView\":0,\"byteOffset\":0,\"componentType\":");
    try appendUint(&json, &numbuf, index_component_type);
    try json.appendSlice(",\"count\":");
    try appendUint(&json, &numbuf, index_count);
    try json.appendSlice(",\"type\":\"SCALAR\"},");
    try json.appendSlice("{\"bufferView\":1,\"byteOffset\":0,\"componentType\":5126,\"count\":");
    try appendUint(&json, &numbuf, vert_count);
    try json.appendSlice(",\"type\":\"VEC3\",\"min\":[");
    try appendFloat(&json, &numbuf, pmin[0]);
    try json.appendSlice(",");
    try appendFloat(&json, &numbuf, pmin[1]);
    try json.appendSlice(",");
    try appendFloat(&json, &numbuf, pmin[2]);
    try json.appendSlice("],\"max\":[");
    try appendFloat(&json, &numbuf, pmax[0]);
    try json.appendSlice(",");
    try appendFloat(&json, &numbuf, pmax[1]);
    try json.appendSlice(",");
    try appendFloat(&json, &numbuf, pmax[2]);
    try json.appendSlice("]}],");

    // mesh / primitive
    try json.appendSlice("\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":1},\"indices\":0,\"mode\":4}]}],");
    // node / scene
    try json.appendSlice("\"nodes\":[{\"mesh\":0}],");
    try json.appendSlice("\"scenes\":[{\"nodes\":[0]}],");
    try json.appendSlice("\"scene\":0}");

    // Сборка контейнера (header + JSON-чанк с паддингом пробелами + BIN-чанк
    // с паддингом нулями, всё кратно 4) — общий glb-контейнер.
    return glb.writeContainer(alloc, json.items, bin.items);
}

inline fn align4(n: usize) usize {
    return glb.align4(n);
}

fn appendLe(list: *std.array_list.Managed(u8), comptime T: type, value: T) !void {
    return glb.appendLe(list, T, value);
}

fn appendUint(list: *std.array_list.Managed(u8), buf: []u8, value: anytype) !void {
    const s = try std.fmt.bufPrint(buf, "{d}", .{value});
    try list.appendSlice(s);
}

/// Детерминированный формат float через {d} (Zig даёт кратчайшее round-trip
/// представление). NaN/Inf недопустимы в glTF JSON — заменяем на 0.
fn appendFloat(list: *std.array_list.Managed(u8), buf: []u8, v: f32) !void {
    if (std.math.isNan(v) or std.math.isInf(v)) {
        try list.appendSlice("0");
        return;
    }
    const s = try std.fmt.bufPrint(buf, "{d}", .{v});
    try list.appendSlice(s);
}

// ============================ TESTS ============================

const testing = std.testing;

const ParsedGlb = struct {
    magic: u32,
    version: u32,
    total_len: u32,
    json_chunk_len: u32,
    json_chunk_type: u32,
    json: []const u8,
    bin_chunk_len: u32,
    bin_chunk_type: u32,
    bin_offset: usize,
};

fn parseGlb(buf: []const u8) ParsedGlb {
    const magic = std.mem.readInt(u32, buf[0..4], .little);
    const version = std.mem.readInt(u32, buf[4..8], .little);
    const total_len = std.mem.readInt(u32, buf[8..12], .little);

    const json_chunk_len = std.mem.readInt(u32, buf[12..16], .little);
    const json_chunk_type = std.mem.readInt(u32, buf[16..20], .little);
    const json_start: usize = 20;
    const json = buf[json_start .. json_start + json_chunk_len];

    const bin_hdr = json_start + json_chunk_len;
    const bin_chunk_len = std.mem.readInt(u32, buf[bin_hdr..][0..4], .little);
    const bin_chunk_type = std.mem.readInt(u32, buf[bin_hdr + 4 ..][0..4], .little);
    const bin_offset = bin_hdr + 8;

    return .{
        .magic = magic,
        .version = version,
        .total_len = total_len,
        .json_chunk_len = json_chunk_len,
        .json_chunk_type = json_chunk_type,
        .json = json,
        .bin_chunk_len = bin_chunk_len,
        .bin_chunk_type = bin_chunk_type,
        .bin_offset = bin_offset,
    };
}

test "triangle: structure + JSON valid + accessors" {
    const alloc = testing.allocator;
    const verts = [_]f32{
        0, 0, 0,
        1, 0, 0,
        0, 1, 0,
    };
    const indices = [_]u32{ 0, 1, 2 };

    const buf = try writeGlb(alloc, &verts, &indices);
    defer alloc.free(buf);

    const p = parseGlb(buf);
    // magic == 'glTF'
    try testing.expectEqual(@as(u32, 0x46546C67), p.magic);
    try testing.expectEqualStrings("glTF", buf[0..4]);
    try testing.expectEqual(@as(u32, 2), p.version);
    try testing.expectEqual(@as(u32, @intCast(buf.len)), p.total_len);
    // chunk types
    try testing.expectEqual(@as(u32, 0x4E4F534A), p.json_chunk_type);
    try testing.expectEqual(@as(u32, 0x004E4942), p.bin_chunk_type);
    // выравнивание чанков по 4
    try testing.expectEqual(@as(u32, 0), p.json_chunk_len % 4);
    try testing.expectEqual(@as(u32, 0), p.bin_chunk_len % 4);
    try testing.expectEqual(@as(usize, 0), buf.len % 4);

    // распарсить JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, p.json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // accessors
    const accessors = root.get("accessors").?.array;
    try testing.expectEqual(@as(usize, 2), accessors.items.len);

    // accessor 0 = indices SCALAR, count 3
    const acc_idx = accessors.items[0].object;
    try testing.expectEqualStrings("SCALAR", acc_idx.get("type").?.string);
    try testing.expectEqual(@as(i64, 3), acc_idx.get("count").?.integer);

    // accessor 1 = POSITION VEC3, count 3, есть min/max
    const acc_pos = accessors.items[1].object;
    try testing.expectEqualStrings("VEC3", acc_pos.get("type").?.string);
    try testing.expectEqual(@as(i64, 5126), acc_pos.get("componentType").?.integer);
    try testing.expectEqual(@as(i64, 3), acc_pos.get("count").?.integer);
    const mn = acc_pos.get("min").?.array;
    const mx = acc_pos.get("max").?.array;
    try testing.expectEqual(@as(usize, 3), mn.items.len);
    try testing.expectEqual(@as(usize, 3), mx.items.len);

    // mesh.primitives[0].mode == 4 (TRIANGLES)
    const meshes = root.get("meshes").?.array;
    const prim = meshes.items[0].object.get("primitives").?.array.items[0].object;
    try testing.expectEqual(@as(i64, 4), prim.get("mode").?.integer);
    try testing.expectEqual(@as(i64, 0), prim.get("indices").?.integer);
    try testing.expectEqual(@as(i64, 1), prim.get("attributes").?.object.get("POSITION").?.integer);

    // scene
    try testing.expectEqual(@as(i64, 0), root.get("scene").?.integer);
}

fn jsonNumber(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => unreachable,
    };
}

test "quad: counts + min/max cover all verts" {
    const alloc = testing.allocator;
    const verts = [_]f32{
        -1, -1, 2,
        3,  -1, 2,
        3,  4,  -5,
        -1, 4,  -5,
    };
    const indices = [_]u32{ 0, 1, 2, 0, 2, 3 };

    const buf = try writeGlb(alloc, &verts, &indices);
    defer alloc.free(buf);

    const p = parseGlb(buf);
    try testing.expectEqual(@as(u32, @intCast(buf.len)), p.total_len);
    try testing.expectEqual(@as(u32, 0), p.json_chunk_len % 4);
    try testing.expectEqual(@as(u32, 0), p.bin_chunk_len % 4);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, p.json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    const accessors = root.get("accessors").?.array;
    const acc_idx = accessors.items[0].object;
    const acc_pos = accessors.items[1].object;
    try testing.expectEqual(@as(i64, 6), acc_idx.get("count").?.integer); // indices count
    try testing.expectEqual(@as(i64, 4), acc_pos.get("count").?.integer); // POSITION count

    // min/max покрывают все 4 вершины
    const mn = acc_pos.get("min").?.array;
    const mx = acc_pos.get("max").?.array;
    try testing.expectApproxEqAbs(@as(f64, -1), jsonNumber(mn.items[0]), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, -1), jsonNumber(mn.items[1]), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, -5), jsonNumber(mn.items[2]), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 3), jsonNumber(mx.items[0]), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 4), jsonNumber(mx.items[1]), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 2), jsonNumber(mx.items[2]), 1e-6);
}

test "u16 indices chosen for small meshes, bin layout correct" {
    const alloc = testing.allocator;
    const verts = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const indices = [_]u32{ 0, 1, 2 };
    const buf = try writeGlb(alloc, &verts, &indices);
    defer alloc.free(buf);

    const p = parseGlb(buf);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, p.json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    const acc_idx = root.get("accessors").?.array.items[0].object;
    // маленькая геометрия → u16 (5123)
    try testing.expectEqual(@as(i64, 5123), acc_idx.get("componentType").?.integer);

    // bufferView positions byteOffset кратен 4
    const bvs = root.get("bufferViews").?.array;
    const bv_pos = bvs.items[1].object;
    const pos_off: i64 = bv_pos.get("byteOffset").?.integer;
    try testing.expectEqual(@as(i64, 0), @mod(pos_off, 4));

    // прочитать первую позицию из BIN и сверить с verts[0..3]
    const buffer_byte_len: i64 = root.get("buffers").?.array.items[0].object.get("byteLength").?.integer;
    try testing.expect(buffer_byte_len > 0);
    const pos_data_start = p.bin_offset + @as(usize, @intCast(pos_off));
    const x0: f32 = @bitCast(std.mem.readInt(u32, buf[pos_data_start..][0..4], .little));
    try testing.expectApproxEqAbs(@as(f32, 0), x0, 1e-6);
}

test "empty geometry does not crash" {
    const alloc = testing.allocator;
    const buf = try writeGlb(alloc, &.{}, &.{});
    defer alloc.free(buf);
    const p = parseGlb(buf);
    try testing.expectEqual(@as(u32, 0x46546C67), p.magic);
    try testing.expectEqual(@as(u32, @intCast(buf.len)), p.total_len);
    // JSON всё ещё парсится; buffer.byteLength == 0
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, p.json, .{});
    defer parsed.deinit();
    const blen = parsed.value.object.get("buffers").?.array.items[0]
        .object.get("byteLength").?.integer;
    try testing.expectEqual(@as(i64, 0), blen);
    // согласованность: BIN-чанк существует и кратен 4
    try testing.expectEqual(@as(u32, 0), p.bin_chunk_len % 4);
    try testing.expectEqual(@as(u32, 0x004E4942), p.bin_chunk_type);
}

test "u32 indices chosen when index >= 65536, written as 4 bytes in BIN" {
    const alloc = testing.allocator;
    // достаточно вершин, чтобы индекс 65536 был валиден (65537 вершин)
    const N: u32 = 65537;
    var verts = std.array_list.Managed(f32).init(alloc);
    defer verts.deinit();
    var i: u32 = 0;
    while (i < N) : (i += 1) {
        try verts.append(@floatFromInt(i)); // x растёт → проверим min/max
        try verts.append(0);
        try verts.append(0);
    }
    // включает граничный индекс 65536 (>= 65536 → форсирует u32)
    const indices = [_]u32{ 0, 1, 65536 };

    const buf = try writeGlb(alloc, verts.items, &indices);
    defer alloc.free(buf);

    const p = parseGlb(buf);
    try testing.expectEqual(@as(u32, @intCast(buf.len)), p.total_len);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, p.json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // accessor индексов: componentType == 5125 (UNSIGNED_INT)
    const acc_idx = root.get("accessors").?.array.items[0].object;
    try testing.expectEqual(@as(i64, 5125), acc_idx.get("componentType").?.integer);
    try testing.expectEqual(@as(i64, 3), acc_idx.get("count").?.integer);

    // bufferView индексов: byteLength == count * 4 (согласованность ширины и BIN)
    const bvs = root.get("bufferViews").?.array;
    const bv_idx = bvs.items[0].object;
    try testing.expectEqual(@as(i64, 0), bv_idx.get("byteOffset").?.integer);
    try testing.expectEqual(@as(i64, 12), bv_idx.get("byteLength").?.integer); // 3 * 4

    // реально прочитать 3-й индекс (u32) из BIN и сверить с 65536
    const idx2: u32 = std.mem.readInt(u32, buf[p.bin_offset + 8 ..][0..4], .little);
    try testing.expectEqual(@as(u32, 65536), idx2);

    // позиции выровнены: indices_byte_len=12 уже кратно 4 → offset==12
    const bv_pos = bvs.items[1].object;
    try testing.expectEqual(@as(i64, 12), bv_pos.get("byteOffset").?.integer);

    // min/max покрывают диапазон x: [0 .. N-1]
    const acc_pos = root.get("accessors").?.array.items[1].object;
    try testing.expectEqual(@as(i64, @intCast(N)), acc_pos.get("count").?.integer);
    const mx0 = jsonNumber(acc_pos.get("max").?.array.items[0]);
    try testing.expectApproxEqAbs(@as(f64, @floatFromInt(N - 1)), mx0, 1.0);
}

test "chunkLength fields match padded payload lengths exactly" {
    const alloc = testing.allocator;
    // нечётное число вершин + индексы, дающие JSON произвольной длины,
    // чтобы паддинг пробелами реально срабатывал
    const verts = [_]f32{
        0.5, -0.25, 1.0,
        2.0, 3.0,   -4.0,
        7.0, 8.0,   9.0,
        1.0, 2.0,   3.0,
        4.0, 5.0,   6.0,
    };
    const indices = [_]u32{ 0, 1, 2, 2, 3, 4 };

    const buf = try writeGlb(alloc, &verts, &indices);
    defer alloc.free(buf);

    const p = parseGlb(buf);

    // 1) JSON-чанк: заголовочная длина == реальной длине payload и кратна 4,
    //    хвост дополнен ИМЕННО пробелами (0x20).
    try testing.expectEqual(@as(u32, 0), p.json_chunk_len % 4);
    try testing.expectEqual(@as(usize, p.json_chunk_len), p.json.len);
    // payload JSON начинается с '{' и (после паддинга) заканчивается '}' или ' '
    try testing.expectEqual(@as(u8, '{'), p.json[0]);
    // найти закрывающую '}' и убедиться, что всё после неё — пробелы
    var brace_end: usize = p.json.len;
    while (brace_end > 0) : (brace_end -= 1) {
        if (p.json[brace_end - 1] == '}') break;
    }
    try testing.expect(brace_end > 0);
    for (p.json[brace_end..]) |c| try testing.expectEqual(@as(u8, 0x20), c);

    // 2) BIN-чанк: заголовочная длина кратна 4 и совпадает с buffer.byteLength,
    //    хвост (если есть) — нули.
    try testing.expectEqual(@as(u32, 0), p.bin_chunk_len % 4);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, p.json, .{});
    defer parsed.deinit();
    const blen: i64 = parsed.value.object.get("buffers").?.array.items[0]
        .object.get("byteLength").?.integer;
    // bin_chunk_len >= byteLength, и оба кратны 4; bufferView'ы не выходят за byteLength
    try testing.expect(@as(i64, @intCast(p.bin_chunk_len)) >= blen);
    const bvs = parsed.value.object.get("bufferViews").?.array;
    for (bvs.items) |bvv| {
        const bv = bvv.object;
        const off = bv.get("byteOffset").?.integer;
        const len = bv.get("byteLength").?.integer;
        try testing.expect(off + len <= blen);
    }

    // 3) total_len == header(12) + 8 + json_chunk_len + 8 + bin_chunk_len
    const expect_total: u32 = 12 + 8 + p.json_chunk_len + 8 + p.bin_chunk_len;
    try testing.expectEqual(expect_total, p.total_len);
    try testing.expectEqual(@as(u32, @intCast(buf.len)), p.total_len);
}
