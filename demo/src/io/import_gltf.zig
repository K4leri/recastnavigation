//! Узкий glTF 2.0 / glb импортёр геометрии для zig-recast.
//!
//! Поддержано (СТРОГО узкий путь):
//!   - Контейнеры: .glb (бинарный: header + JSON-чанк + BIN-чанк) и .gltf (чистый JSON).
//!   - Буферы: встроенный glb BIN-чанк (buffer[0] без uri) и `data:...;base64,<...>` URI.
//!   - Примитивы: mode отсутствует (деф. 4) ИЛИ mode == 4 (TRIANGLES).
//!   - Accessor POSITION: componentType 5126 (FLOAT), type "VEC3".
//!   - indices (опц.): componentType 5121 (u8) / 5123 (u16) / 5125 (u32), type "SCALAR".
//!   - bufferView byteOffset / byteStride, accessor byteOffset.
//!   - Node-иерархия (scenes[scene].nodes -> children), мировая матрица:
//!     node.matrix (16, column-major) ЛИБО TRS (translation / rotation-кватернион / scale).
//!     Композиция parent * child, трансформ каждой вершины world * vec4(x,y,z,1).
//!   - Аккумуляция нескольких примитивов/узлов в один Mesh со смещением индексов.
//!
//! НЕ поддержано (выдаёт явную ошибку):
//!   - sparse accessors                  -> error.SparseAccessorUnsupported
//!   - mode != TRIANGLES                  -> error.UnsupportedPrimitiveMode
//!   - POSITION не VEC3/FLOAT             -> error.UnsupportedPositionAccessor
//!   - indices не SCALAR/невалидный тип   -> error.UnsupportedIndexComponentType
//!   - внешние file-URI буферов           -> error.ExternalBufferUnsupported
//!   - отсутствие нужных секций           -> error.MissingSection / error.InvalidGltf
//!
//! Никаких проектных зависимостей: только std (для автономного `zig test`).

const std = @import("std");

pub const Mesh = struct {
    verts: []f32, // owned; тройки x,y,z (в world-space после node-трансформов)
    tris: []i32, // owned; по 3 индекса на треугольник

    pub fn deinit(self: Mesh, alloc: std.mem.Allocator) void {
        alloc.free(self.verts);
        alloc.free(self.tris);
    }
};

pub const Error = error{
    InvalidGltf,
    MissingSection,
    UnsupportedPrimitiveMode,
    UnsupportedPositionAccessor,
    UnsupportedIndexComponentType,
    SparseAccessorUnsupported,
    ExternalBufferUnsupported,
    UnsupportedBufferUri,
    BufferOutOfRange,
    BadGlb,
};

// ---------------------------------------------------------------------------
// Локальная 4x4 матрица (column-major, как в glTF).
// Хранение: m[col*4 + row]. v' = M * v.
// ---------------------------------------------------------------------------
const Mat4 = struct {
    m: [16]f32,

    fn identity() Mat4 {
        return .{ .m = .{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        } };
    }

    /// result = a * b (применяется b, затем a).
    fn mul(a: Mat4, b: Mat4) Mat4 {
        var r: Mat4 = undefined;
        var col: usize = 0;
        while (col < 4) : (col += 1) {
            var row: usize = 0;
            while (row < 4) : (row += 1) {
                var sum: f32 = 0;
                var k: usize = 0;
                while (k < 4) : (k += 1) {
                    // a[row,k] * b[k,col] ; a[row,k] = a.m[k*4+row], b[k,col] = b.m[col*4+k]
                    sum += a.m[k * 4 + row] * b.m[col * 4 + k];
                }
                r.m[col * 4 + row] = sum;
            }
        }
        return r;
    }

    /// Трансформировать точку (w=1), вернуть xyz.
    fn transformPoint(self: Mat4, x: f32, y: f32, z: f32) [3]f32 {
        // res[row] = sum_col m[col*4+row] * v[col], v = (x,y,z,1)
        const rx = self.m[0] * x + self.m[4] * y + self.m[8] * z + self.m[12];
        const ry = self.m[1] * x + self.m[5] * y + self.m[9] * z + self.m[13];
        const rz = self.m[2] * x + self.m[6] * y + self.m[10] * z + self.m[14];
        return .{ rx, ry, rz };
    }

    fn fromTranslation(t: [3]f32) Mat4 {
        var r = identity();
        r.m[12] = t[0];
        r.m[13] = t[1];
        r.m[14] = t[2];
        return r;
    }

    fn fromScale(s: [3]f32) Mat4 {
        var r = identity();
        r.m[0] = s[0];
        r.m[5] = s[1];
        r.m[10] = s[2];
        return r;
    }

    /// Кватернион (x,y,z,w) -> матрица вращения (column-major).
    fn fromQuat(q: [4]f32) Mat4 {
        const x = q[0];
        const y = q[1];
        const z = q[2];
        const w = q[3];
        const xx = x * x;
        const yy = y * y;
        const zz = z * z;
        const xy = x * y;
        const xz = x * z;
        const yz = y * z;
        const wx = w * x;
        const wy = w * y;
        const wz = w * z;
        var r = identity();
        // column-major: m[col*4+row]
        // col0
        r.m[0] = 1 - 2 * (yy + zz);
        r.m[1] = 2 * (xy + wz);
        r.m[2] = 2 * (xz - wy);
        // col1
        r.m[4] = 2 * (xy - wz);
        r.m[5] = 1 - 2 * (xx + zz);
        r.m[6] = 2 * (yz + wx);
        // col2
        r.m[8] = 2 * (xz + wy);
        r.m[9] = 2 * (yz - wx);
        r.m[10] = 1 - 2 * (xx + yy);
        return r;
    }
};

// ---------------------------------------------------------------------------
// JSON-хелперы (std.json.Value).
// ---------------------------------------------------------------------------
const V = std.json.Value;

fn objGet(v: V, key: []const u8) ?V {
    if (v != .object) return null;
    return v.object.get(key);
}

fn asInt(v: V) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn asF32(v: V) ?f32 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => null,
    };
}

fn getInt(v: V, key: []const u8) ?i64 {
    const x = objGet(v, key) orelse return null;
    return asInt(x);
}

fn getArray(v: V, key: []const u8) ?std.json.Array {
    const x = objGet(v, key) orelse return null;
    if (x != .array) return null;
    return x.array;
}

/// Прочитать массив фиксированной длины из чисел в out.
fn readFixedFloats(v: V, key: []const u8, out: []f32) bool {
    const arr = getArray(v, key) orelse return false;
    if (arr.items.len != out.len) return false;
    for (arr.items, 0..) |it, i| {
        out[i] = asF32(it) orelse return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Парсинг glb-контейнера: возвращает JSON-байты и опц. BIN-чанк.
// ---------------------------------------------------------------------------
const GlbChunks = struct {
    json: []const u8,
    bin: ?[]const u8,
};

fn readU32LE(bytes: []const u8, off: usize) Error!u32 {
    if (off + 4 > bytes.len) return Error.BadGlb;
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

fn parseGlb(bytes: []const u8) Error!GlbChunks {
    if (bytes.len < 12) return Error.BadGlb;
    const magic = try readU32LE(bytes, 0);
    if (magic != 0x46546C67) return Error.BadGlb; // 'glTF'
    const version = try readU32LE(bytes, 4);
    if (version != 2) return Error.BadGlb;
    const total_len = try readU32LE(bytes, 8);
    if (total_len > bytes.len) return Error.BadGlb;

    var json: ?[]const u8 = null;
    var bin: ?[]const u8 = null;

    var off: usize = 12;
    while (off + 8 <= total_len) {
        const chunk_len: usize = @intCast(try readU32LE(bytes, off));
        const chunk_type = try readU32LE(bytes, off + 4);
        const data_start = off + 8;
        const data_end = data_start + chunk_len;
        if (data_end > total_len or data_end > bytes.len) return Error.BadGlb;
        const data = bytes[data_start..data_end];
        switch (chunk_type) {
            0x4E4F534A => json = data, // 'JSON'
            0x004E4942 => bin = data, //  'BIN\0'
            else => {}, // прочие чанки игнорируем
        }
        off = data_end;
    }

    const j = json orelse return Error.BadGlb;
    return .{ .json = j, .bin = bin };
}

fn isGlb(bytes: []const u8) bool {
    if (bytes.len < 4) return false;
    return std.mem.readInt(u32, bytes[0..4], .little) == 0x46546C67;
}

// ---------------------------------------------------------------------------
// Разрешение буферов.
// ---------------------------------------------------------------------------
const Buffer = struct {
    data: []const u8,
    owned: bool, // true => data выделена через alloc (base64), нужно free
};

/// Разрешить все buffers[]. glb_bin — BIN-чанк (для buffer без uri).
fn resolveBuffers(
    alloc: std.mem.Allocator,
    root: V,
    glb_bin: ?[]const u8,
    out: *std.array_list.Managed(Buffer),
) !void {
    const buffers = getArray(root, "buffers") orelse {
        // Допустимо иметь 0 буферов? Для геометрии — нет, но решит вызывающий.
        return;
    };
    for (buffers.items) |buf| {
        const uri_v = objGet(buf, "uri");
        if (uri_v == null) {
            // Буфер без uri -> glb BIN-чанк.
            const bin = glb_bin orelse return Error.MissingSection;
            try out.append(.{ .data = bin, .owned = false });
            continue;
        }
        const uri = switch (uri_v.?) {
            .string => |s| s,
            else => return Error.InvalidGltf,
        };
        if (std.mem.startsWith(u8, uri, "data:")) {
            // data:[<mime>][;base64],<payload>
            const comma = std.mem.indexOfScalar(u8, uri, ',') orelse return Error.UnsupportedBufferUri;
            const header = uri[0..comma];
            const payload = uri[comma + 1 ..];
            if (std.mem.indexOf(u8, header, ";base64") == null) {
                // только base64-data поддержан
                return Error.UnsupportedBufferUri;
            }
            const dec = std.base64.standard.Decoder;
            const n = dec.calcSizeForSlice(payload) catch return Error.UnsupportedBufferUri;
            const decoded = try alloc.alloc(u8, n);
            errdefer alloc.free(decoded);
            dec.decode(decoded, payload) catch {
                alloc.free(decoded);
                return Error.UnsupportedBufferUri;
            };
            try out.append(.{ .data = decoded, .owned = true });
        } else {
            // Внешний файловый URI — для parse(bytes) не поддержан.
            return Error.ExternalBufferUnsupported;
        }
    }
}

fn freeBuffers(alloc: std.mem.Allocator, buffers: []Buffer) void {
    for (buffers) |b| {
        if (b.owned) alloc.free(b.data);
    }
}

// ---------------------------------------------------------------------------
// Чтение accessor -> срез байтов с учётом bufferView.
// ---------------------------------------------------------------------------
const AccessorView = struct {
    buffer_data: []const u8,
    base_offset: usize, // bufferView.byteOffset + accessor.byteOffset
    stride: usize, // эффективный stride элемента
    count: usize, // accessor.count
    component_size: usize, // байт на компонент
    num_components: usize, // компонентов на элемент (3 для VEC3, 1 для SCALAR)
};

fn componentSize(component_type: i64) ?usize {
    return switch (component_type) {
        5120, 5121 => 1, // BYTE / UNSIGNED_BYTE
        5122, 5123 => 2, // SHORT / UNSIGNED_SHORT
        5125, 5126 => 4, // UNSIGNED_INT / FLOAT
        else => null,
    };
}

fn numComponents(type_str: []const u8) ?usize {
    if (std.mem.eql(u8, type_str, "SCALAR")) return 1;
    if (std.mem.eql(u8, type_str, "VEC2")) return 2;
    if (std.mem.eql(u8, type_str, "VEC3")) return 3;
    if (std.mem.eql(u8, type_str, "VEC4")) return 4;
    if (std.mem.eql(u8, type_str, "MAT2")) return 4;
    if (std.mem.eql(u8, type_str, "MAT3")) return 9;
    if (std.mem.eql(u8, type_str, "MAT4")) return 16;
    return null;
}

const Gltf = struct {
    root: V,
    buffers: []Buffer,
    accessors: std.json.Array,
    buffer_views: std.json.Array,

    fn accessorView(self: Gltf, accessor_index: i64) Error!AccessorView {
        if (accessor_index < 0 or @as(usize, @intCast(accessor_index)) >= self.accessors.items.len)
            return Error.InvalidGltf;
        const acc = self.accessors.items[@intCast(accessor_index)];

        if (objGet(acc, "sparse") != null) return Error.SparseAccessorUnsupported;

        const ct = getInt(acc, "componentType") orelse return Error.InvalidGltf;
        const type_v = objGet(acc, "type") orelse return Error.InvalidGltf;
        const type_str = switch (type_v) {
            .string => |s| s,
            else => return Error.InvalidGltf,
        };
        const count_i = getInt(acc, "count") orelse return Error.InvalidGltf;
        if (count_i < 0) return Error.InvalidGltf;

        const csize = componentSize(ct) orelse return Error.InvalidGltf;
        const ncomp = numComponents(type_str) orelse return Error.InvalidGltf;
        const acc_offset: usize = @intCast(getInt(acc, "byteOffset") orelse 0);

        const bv_index = getInt(acc, "bufferView") orelse return Error.InvalidGltf;
        if (bv_index < 0 or @as(usize, @intCast(bv_index)) >= self.buffer_views.items.len)
            return Error.InvalidGltf;
        const bv = self.buffer_views.items[@intCast(bv_index)];

        const buf_index = getInt(bv, "buffer") orelse return Error.InvalidGltf;
        if (buf_index < 0 or @as(usize, @intCast(buf_index)) >= self.buffers.len)
            return Error.InvalidGltf;
        const buf = self.buffers[@intCast(buf_index)];

        const bv_offset: usize = @intCast(getInt(bv, "byteOffset") orelse 0);
        const elem_size = csize * ncomp;
        const stride: usize = blk: {
            const bs = getInt(bv, "byteStride") orelse 0;
            if (bs <= 0) break :blk elem_size;
            break :blk @intCast(bs);
        };

        return .{
            .buffer_data = buf.data,
            .base_offset = bv_offset + acc_offset,
            .stride = stride,
            .count = @intCast(count_i),
            .component_size = csize,
            .num_components = ncomp,
        };
    }
};

fn readF32(data: []const u8, off: usize) Error!f32 {
    if (off + 4 > data.len) return Error.BufferOutOfRange;
    const bits = std.mem.readInt(u32, data[off..][0..4], .little);
    return @bitCast(bits);
}

// ---------------------------------------------------------------------------
// Публичный API.
// ---------------------------------------------------------------------------

/// Разобрать glTF (.gltf JSON) ИЛИ glb (бинарный контейнер) из байтов.
pub fn parse(alloc: std.mem.Allocator, bytes: []const u8) !Mesh {
    var glb_bin: ?[]const u8 = null;
    var json_bytes: []const u8 = bytes;

    if (isGlb(bytes)) {
        const chunks = try parseGlb(bytes);
        json_bytes = chunks.json;
        glb_bin = chunks.bin;
    }

    var parsed = std.json.parseFromSlice(V, alloc, json_bytes, .{}) catch return Error.InvalidGltf;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return Error.InvalidGltf;

    // Буферы.
    var buf_list = std.array_list.Managed(Buffer).init(alloc);
    defer {
        freeBuffers(alloc, buf_list.items);
        buf_list.deinit();
    }
    try resolveBuffers(alloc, root, glb_bin, &buf_list);

    const accessors = getArray(root, "accessors") orelse return Error.MissingSection;
    const buffer_views = getArray(root, "bufferViews") orelse return Error.MissingSection;
    const meshes = getArray(root, "meshes") orelse return Error.MissingSection;
    const nodes = getArray(root, "nodes") orelse return Error.MissingSection;

    const gltf = Gltf{
        .root = root,
        .buffers = buf_list.items,
        .accessors = accessors,
        .buffer_views = buffer_views,
    };

    // Аккумуляторы вывода.
    var out_verts = std.array_list.Managed(f32).init(alloc);
    errdefer out_verts.deinit();
    var out_tris = std.array_list.Managed(i32).init(alloc);
    errdefer out_tris.deinit();

    // Определить корневые узлы сцены.
    const scene_index: usize = blk: {
        if (getInt(root, "scene")) |s| {
            if (s >= 0) break :blk @intCast(s);
        }
        break :blk 0;
    };

    var root_nodes_storage: ?std.json.Array = null;
    var root_node_list: []const V = undefined;
    if (getArray(root, "scenes")) |scenes| {
        if (scene_index < scenes.items.len) {
            if (getArray(scenes.items[scene_index], "nodes")) |sn| {
                root_nodes_storage = sn;
                root_node_list = sn.items;
            }
        }
    }
    // Фолбэк: если нет scenes — обойти все узлы как корни.
    var all_indices: ?std.array_list.Managed(V) = null;
    defer if (all_indices) |*ai| ai.deinit();
    if (root_nodes_storage == null) {
        var ai = std.array_list.Managed(V).init(alloc);
        var i: i64 = 0;
        while (i < @as(i64, @intCast(nodes.items.len))) : (i += 1) {
            try ai.append(.{ .integer = i });
        }
        all_indices = ai;
        root_node_list = ai.items;
    }

    // Обход иерархии.
    for (root_node_list) |node_idx_v| {
        const idx = asInt(node_idx_v) orelse return Error.InvalidGltf;
        try walkNode(&gltf, nodes, meshes, idx, Mat4.identity(), &out_verts, &out_tris);
    }

    return .{
        .verts = try out_verts.toOwnedSlice(),
        .tris = try out_tris.toOwnedSlice(),
    };
}

/// Локальная матрица узла.
fn nodeLocalMatrix(node: V) Error!Mat4 {
    // node.matrix имеет приоритет (по спеке matrix и TRS взаимоисключающи).
    var mat_buf: [16]f32 = undefined;
    if (readFixedFloats(node, "matrix", &mat_buf)) {
        return .{ .m = mat_buf };
    }
    // TRS.
    var t = [3]f32{ 0, 0, 0 };
    var r = [4]f32{ 0, 0, 0, 1 };
    var s = [3]f32{ 1, 1, 1 };
    _ = readFixedFloats(node, "translation", &t);
    _ = readFixedFloats(node, "rotation", &r);
    _ = readFixedFloats(node, "scale", &s);
    const tm = Mat4.fromTranslation(t);
    const rm = Mat4.fromQuat(r);
    const sm = Mat4.fromScale(s);
    // M = T * R * S
    return tm.mul(rm).mul(sm);
}

fn walkNode(
    gltf: *const Gltf,
    nodes: std.json.Array,
    meshes: std.json.Array,
    node_index: i64,
    parent_world: Mat4,
    out_verts: *std.array_list.Managed(f32),
    out_tris: *std.array_list.Managed(i32),
) !void {
    if (node_index < 0 or @as(usize, @intCast(node_index)) >= nodes.items.len)
        return Error.InvalidGltf;
    const node = nodes.items[@intCast(node_index)];

    const local = try nodeLocalMatrix(node);
    const world = parent_world.mul(local);

    if (getInt(node, "mesh")) |mesh_idx| {
        if (mesh_idx < 0 or @as(usize, @intCast(mesh_idx)) >= meshes.items.len)
            return Error.InvalidGltf;
        try emitMesh(gltf, meshes.items[@intCast(mesh_idx)], world, out_verts, out_tris);
    }

    if (getArray(node, "children")) |children| {
        for (children.items) |c| {
            const ci = asInt(c) orelse return Error.InvalidGltf;
            try walkNode(gltf, nodes, meshes, ci, world, out_verts, out_tris);
        }
    }
}

fn emitMesh(
    gltf: *const Gltf,
    mesh: V,
    world: Mat4,
    out_verts: *std.array_list.Managed(f32),
    out_tris: *std.array_list.Managed(i32),
) !void {
    const primitives = getArray(mesh, "primitives") orelse return Error.InvalidGltf;
    for (primitives.items) |prim| {
        // mode: отсутствует -> 4 (TRIANGLES).
        const mode = getInt(prim, "mode") orelse 4;
        if (mode != 4) return Error.UnsupportedPrimitiveMode;

        const attrs = objGet(prim, "attributes") orelse return Error.InvalidGltf;
        const pos_acc_v = objGet(attrs, "POSITION") orelse return Error.InvalidGltf;
        const pos_acc = asInt(pos_acc_v) orelse return Error.InvalidGltf;

        // Валидация типа POSITION accessor.
        {
            if (pos_acc < 0 or @as(usize, @intCast(pos_acc)) >= gltf.accessors.items.len)
                return Error.InvalidGltf;
            const acc = gltf.accessors.items[@intCast(pos_acc)];
            const ct = getInt(acc, "componentType") orelse return Error.InvalidGltf;
            const tv = objGet(acc, "type") orelse return Error.InvalidGltf;
            const ts = switch (tv) {
                .string => |s| s,
                else => return Error.InvalidGltf,
            };
            if (ct != 5126 or !std.mem.eql(u8, ts, "VEC3"))
                return Error.UnsupportedPositionAccessor;
        }

        const view = try gltf.accessorView(pos_acc);
        // base_vertex — сколько вершин уже накоплено (для смещения индексов).
        const base_vertex: i32 = @intCast(@divExact(@as(i64, @intCast(out_verts.items.len)), 3));

        // Читаем и трансформируем позиции.
        var i: usize = 0;
        while (i < view.count) : (i += 1) {
            const elem_off = view.base_offset + i * view.stride;
            const x = try readF32(view.buffer_data, elem_off);
            const y = try readF32(view.buffer_data, elem_off + 4);
            const z = try readF32(view.buffer_data, elem_off + 8);
            const p = world.transformPoint(x, y, z);
            try out_verts.append(p[0]);
            try out_verts.append(p[1]);
            try out_verts.append(p[2]);
        }

        // indices (опц.).
        if (getInt(prim, "indices")) |idx_acc| {
            const iv = try gltf.accessorView(idx_acc);
            if (iv.num_components != 1) return Error.UnsupportedIndexComponentType;
            const acc = gltf.accessors.items[@intCast(idx_acc)];
            const tv = objGet(acc, "type") orelse return Error.InvalidGltf;
            const ts = switch (tv) {
                .string => |s| s,
                else => return Error.InvalidGltf,
            };
            if (!std.mem.eql(u8, ts, "SCALAR")) return Error.UnsupportedIndexComponentType;

            var j: usize = 0;
            while (j < iv.count) : (j += 1) {
                const off = iv.base_offset + j * iv.stride;
                const raw: i64 = switch (iv.component_size) {
                    1 => blk: {
                        if (off + 1 > iv.buffer_data.len) return Error.BufferOutOfRange;
                        break :blk @intCast(iv.buffer_data[off]);
                    },
                    2 => blk: {
                        if (off + 2 > iv.buffer_data.len) return Error.BufferOutOfRange;
                        break :blk @intCast(std.mem.readInt(u16, iv.buffer_data[off..][0..2], .little));
                    },
                    4 => blk: {
                        if (off + 4 > iv.buffer_data.len) return Error.BufferOutOfRange;
                        break :blk @intCast(std.mem.readInt(u32, iv.buffer_data[off..][0..4], .little));
                    },
                    else => return Error.UnsupportedIndexComponentType,
                };
                try out_tris.append(base_vertex + @as(i32, @intCast(raw)));
            }
        } else {
            // Без indices — вершины подряд тройками.
            var k: usize = 0;
            while (k < view.count) : (k += 1) {
                try out_tris.append(base_vertex + @as(i32, @intCast(k)));
            }
        }
    }
}

// ===========================================================================
// ТЕСТЫ
// ===========================================================================

const testing = std.testing;

/// Сериализатор для построения glb в тестах.
const GlbBuilder = struct {
    fn build(alloc: std.mem.Allocator, json: []const u8, bin: []const u8) ![]u8 {
        // Паддинг JSON до 4 байт пробелами, BIN до 4 байт нулями.
        const json_pad = (4 - (json.len % 4)) % 4;
        const bin_pad = (4 - (bin.len % 4)) % 4;
        const json_chunk_len = json.len + json_pad;
        const bin_chunk_len = bin.len + bin_pad;

        const total: usize = 12 + 8 + json_chunk_len + 8 + bin_chunk_len;
        var out = try alloc.alloc(u8, total);
        errdefer alloc.free(out);

        var w: usize = 0;
        // header
        std.mem.writeInt(u32, out[w..][0..4], 0x46546C67, .little);
        w += 4;
        std.mem.writeInt(u32, out[w..][0..4], 2, .little);
        w += 4;
        std.mem.writeInt(u32, out[w..][0..4], @intCast(total), .little);
        w += 4;
        // JSON chunk
        std.mem.writeInt(u32, out[w..][0..4], @intCast(json_chunk_len), .little);
        w += 4;
        std.mem.writeInt(u32, out[w..][0..4], 0x4E4F534A, .little);
        w += 4;
        @memcpy(out[w .. w + json.len], json);
        w += json.len;
        var p: usize = 0;
        while (p < json_pad) : (p += 1) {
            out[w] = ' ';
            w += 1;
        }
        // BIN chunk
        std.mem.writeInt(u32, out[w..][0..4], @intCast(bin_chunk_len), .little);
        w += 4;
        std.mem.writeInt(u32, out[w..][0..4], 0x004E4942, .little);
        w += 4;
        @memcpy(out[w .. w + bin.len], bin);
        w += bin.len;
        p = 0;
        while (p < bin_pad) : (p += 1) {
            out[w] = 0;
            w += 1;
        }
        std.debug.assert(w == total);
        return out;
    }
};

/// Построить BIN-буфер: 3 вершины FLOAT VEC3 + 3 индекса u16.
/// Возвращает (bin_bytes, pos_byte_len, idx_byte_offset, idx_byte_len).
fn buildTriangleBin(alloc: std.mem.Allocator, verts: [9]f32, indices: []const u16) ![]u8 {
    const pos_len = 9 * 4;
    const idx_len = indices.len * 2;
    const bin = try alloc.alloc(u8, pos_len + idx_len);
    var w: usize = 0;
    for (verts) |f| {
        std.mem.writeInt(u32, bin[w..][0..4], @bitCast(f), .little);
        w += 4;
    }
    for (indices) |ix| {
        std.mem.writeInt(u16, bin[w..][0..2], ix, .little);
        w += 2;
    }
    return bin;
}

test "glb: simple triangle with u16 indices" {
    const alloc = testing.allocator;
    const verts = [9]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const indices = [_]u16{ 0, 1, 2 };
    const bin = try buildTriangleBin(alloc, verts, &indices);
    defer alloc.free(bin);

    const json =
        \\{
        \\ "buffers":[{"byteLength":42}],
        \\ "bufferViews":[
        \\   {"buffer":0,"byteOffset":0,"byteLength":36},
        \\   {"buffer":0,"byteOffset":36,"byteLength":6}
        \\ ],
        \\ "accessors":[
        \\   {"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
        \\   {"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}
        \\ ],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1,"mode":4}]}],
        \\ "nodes":[{"mesh":0}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "scene":0
        \\}
    ;
    const glb = try GlbBuilder.build(alloc, json, bin);
    defer alloc.free(glb);

    var mesh = try parse(alloc, glb);
    defer mesh.deinit(alloc);

    try testing.expectEqual(@as(usize, 9), mesh.verts.len);
    try testing.expectEqual(@as(usize, 3), mesh.tris.len);
    try testing.expectEqualSlices(i32, &[_]i32{ 0, 1, 2 }, mesh.tris);
    try testing.expectApproxEqAbs(@as(f32, 0), mesh.verts[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), mesh.verts[3], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), mesh.verts[7], 1e-6);
}

test "glb: node.matrix translation (10,0,0)" {
    const alloc = testing.allocator;
    const verts = [9]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const indices = [_]u16{ 0, 1, 2 };
    const bin = try buildTriangleBin(alloc, verts, &indices);
    defer alloc.free(bin);

    // matrix column-major с translation (10,0,0): последний столбец [10,0,0,1].
    const json =
        \\{
        \\ "buffers":[{"byteLength":42}],
        \\ "bufferViews":[
        \\   {"buffer":0,"byteOffset":0,"byteLength":36},
        \\   {"buffer":0,"byteOffset":36,"byteLength":6}
        \\ ],
        \\ "accessors":[
        \\   {"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
        \\   {"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}
        \\ ],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}],
        \\ "nodes":[{"mesh":0,"matrix":[1,0,0,0, 0,1,0,0, 0,0,1,0, 10,0,0,1]}],
        \\ "scenes":[{"nodes":[0]}]
        \\}
    ;
    const glb = try GlbBuilder.build(alloc, json, bin);
    defer alloc.free(glb);

    var mesh = try parse(alloc, glb);
    defer mesh.deinit(alloc);

    try testing.expectEqual(@as(usize, 9), mesh.verts.len);
    // x всех вершин +10.
    try testing.expectApproxEqAbs(@as(f32, 10), mesh.verts[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 11), mesh.verts[3], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 10), mesh.verts[6], 1e-6);
    // y/z неизменны.
    try testing.expectApproxEqAbs(@as(f32, 1), mesh.verts[7], 1e-6);
}

test "glb: TRS translation via translation field" {
    const alloc = testing.allocator;
    const verts = [9]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const indices = [_]u16{ 0, 1, 2 };
    const bin = try buildTriangleBin(alloc, verts, &indices);
    defer alloc.free(bin);

    const json =
        \\{
        \\ "buffers":[{"byteLength":42}],
        \\ "bufferViews":[
        \\   {"buffer":0,"byteOffset":0,"byteLength":36},
        \\   {"buffer":0,"byteOffset":36,"byteLength":6}
        \\ ],
        \\ "accessors":[
        \\   {"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
        \\   {"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}
        \\ ],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}],
        \\ "nodes":[{"mesh":0,"translation":[0,5,0]}],
        \\ "scenes":[{"nodes":[0]}]
        \\}
    ;
    const glb = try GlbBuilder.build(alloc, json, bin);
    defer alloc.free(glb);

    var mesh = try parse(alloc, glb);
    defer mesh.deinit(alloc);

    try testing.expectApproxEqAbs(@as(f32, 5), mesh.verts[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 5), mesh.verts[4], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 6), mesh.verts[7], 1e-6);
}

test "gltf: data:base64 buffer" {
    const alloc = testing.allocator;
    const verts = [9]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const indices = [_]u16{ 0, 1, 2 };
    const bin = try buildTriangleBin(alloc, verts, &indices);
    defer alloc.free(bin);

    // base64-кодируем bin.
    const enc = std.base64.standard.Encoder;
    const b64_len = enc.calcSize(bin.len);
    const b64 = try alloc.alloc(u8, b64_len);
    defer alloc.free(b64);
    _ = enc.encode(b64, bin);

    const uri_prefix = "data:application/octet-stream;base64,";
    const json = try std.fmt.allocPrint(alloc,
        \\{{
        \\ "buffers":[{{"uri":"{s}{s}","byteLength":42}}],
        \\ "bufferViews":[
        \\   {{"buffer":0,"byteOffset":0,"byteLength":36}},
        \\   {{"buffer":0,"byteOffset":36,"byteLength":6}}
        \\ ],
        \\ "accessors":[
        \\   {{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}},
        \\   {{"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}}
        \\ ],
        \\ "meshes":[{{"primitives":[{{"attributes":{{"POSITION":0}},"indices":1}}]}}],
        \\ "nodes":[{{"mesh":0}}],
        \\ "scenes":[{{"nodes":[0]}}]
        \\}}
    , .{ uri_prefix, b64 });
    defer alloc.free(json);

    var mesh = try parse(alloc, json);
    defer mesh.deinit(alloc);

    try testing.expectEqual(@as(usize, 9), mesh.verts.len);
    try testing.expectEqualSlices(i32, &[_]i32{ 0, 1, 2 }, mesh.tris);
    try testing.expectApproxEqAbs(@as(f32, 1), mesh.verts[3], 1e-6);
}

test "error: non-TRIANGLES mode" {
    const alloc = testing.allocator;
    const verts = [9]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const indices = [_]u16{ 0, 1, 2 };
    const bin = try buildTriangleBin(alloc, verts, &indices);
    defer alloc.free(bin);

    const json =
        \\{
        \\ "buffers":[{"byteLength":42}],
        \\ "bufferViews":[
        \\   {"buffer":0,"byteOffset":0,"byteLength":36},
        \\   {"buffer":0,"byteOffset":36,"byteLength":6}
        \\ ],
        \\ "accessors":[
        \\   {"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
        \\   {"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}
        \\ ],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1,"mode":1}]}],
        \\ "nodes":[{"mesh":0}],
        \\ "scenes":[{"nodes":[0]}]
        \\}
    ;
    const glb = try GlbBuilder.build(alloc, json, bin);
    defer alloc.free(glb);

    try testing.expectError(Error.UnsupportedPrimitiveMode, parse(alloc, glb));
}

test "glb: quad from two primitives accumulates with index offset" {
    const alloc = testing.allocator;
    // 6 вершин (две тройки), две группы индексов.
    // prim0: верт 0,1,2 idx [0,1,2]; prim1: верт 3,4,5 idx [0,1,2] -> сместятся на 3.
    const verts: [18]f32 = .{
        0, 0, 0, 1, 0, 0, 0, 1, 0, // tri0
        1, 1, 0, 0, 1, 0, 1, 0, 0, // tri1
    };
    const bin = try alloc.alloc(u8, 18 * 4 + 6 * 2);
    defer alloc.free(bin);
    var w: usize = 0;
    for (verts) |f| {
        std.mem.writeInt(u32, bin[w..][0..4], @bitCast(f), .little);
        w += 4;
    }
    // indices для обоих примитивов: один bufferView с [0,1,2].
    const idxs = [_]u16{ 0, 1, 2 };
    for (idxs) |ix| {
        std.mem.writeInt(u16, bin[w..][0..2], ix, .little);
        w += 2;
    }

    // bufferView: pos0 (0..36), pos1 (36..72), idx (72..78).
    const json =
        \\{
        \\ "buffers":[{"byteLength":78}],
        \\ "bufferViews":[
        \\   {"buffer":0,"byteOffset":0,"byteLength":36},
        \\   {"buffer":0,"byteOffset":36,"byteLength":36},
        \\   {"buffer":0,"byteOffset":72,"byteLength":6}
        \\ ],
        \\ "accessors":[
        \\   {"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
        \\   {"bufferView":1,"componentType":5126,"count":3,"type":"VEC3"},
        \\   {"bufferView":2,"componentType":5123,"count":3,"type":"SCALAR"}
        \\ ],
        \\ "meshes":[{"primitives":[
        \\   {"attributes":{"POSITION":0},"indices":2,"mode":4},
        \\   {"attributes":{"POSITION":1},"indices":2,"mode":4}
        \\ ]}],
        \\ "nodes":[{"mesh":0}],
        \\ "scenes":[{"nodes":[0]}]
        \\}
    ;
    const glb = try GlbBuilder.build(alloc, json, bin);
    defer alloc.free(glb);

    var mesh = try parse(alloc, glb);
    defer mesh.deinit(alloc);

    try testing.expectEqual(@as(usize, 18), mesh.verts.len);
    try testing.expectEqual(@as(usize, 6), mesh.tris.len);
    // Первый примитив: 0,1,2; второй смещён на 3: 3,4,5.
    try testing.expectEqualSlices(i32, &[_]i32{ 0, 1, 2, 3, 4, 5 }, mesh.tris);
}

test "glb: no indices -> sequential triangles" {
    const alloc = testing.allocator;
    const verts = [9]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    // только позиции, без indices буфера.
    const bin = try alloc.alloc(u8, 9 * 4);
    defer alloc.free(bin);
    var w: usize = 0;
    for (verts) |f| {
        std.mem.writeInt(u32, bin[w..][0..4], @bitCast(f), .little);
        w += 4;
    }

    const json =
        \\{
        \\ "buffers":[{"byteLength":36}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
        \\ "nodes":[{"mesh":0}],
        \\ "scenes":[{"nodes":[0]}]
        \\}
    ;
    const glb = try GlbBuilder.build(alloc, json, bin);
    defer alloc.free(glb);

    var mesh = try parse(alloc, glb);
    defer mesh.deinit(alloc);

    try testing.expectEqualSlices(i32, &[_]i32{ 0, 1, 2 }, mesh.tris);
}

test "error: sparse accessor unsupported" {
    const alloc = testing.allocator;
    const verts = [9]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const bin = try alloc.alloc(u8, 9 * 4);
    defer alloc.free(bin);
    var w: usize = 0;
    for (verts) |f| {
        std.mem.writeInt(u32, bin[w..][0..4], @bitCast(f), .little);
        w += 4;
    }
    const json =
        \\{
        \\ "buffers":[{"byteLength":36}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","sparse":{"count":1}}],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
        \\ "nodes":[{"mesh":0}],
        \\ "scenes":[{"nodes":[0]}]
        \\}
    ;
    const glb = try GlbBuilder.build(alloc, json, bin);
    defer alloc.free(glb);
    try testing.expectError(Error.SparseAccessorUnsupported, parse(alloc, glb));
}

test "error: external buffer uri unsupported" {
    const alloc = testing.allocator;
    const json =
        \\{
        \\ "buffers":[{"uri":"scene.bin","byteLength":36}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
        \\ "nodes":[{"mesh":0}],
        \\ "scenes":[{"nodes":[0]}]
        \\}
    ;
    try testing.expectError(Error.ExternalBufferUnsupported, parse(alloc, json));
}

test "error: POSITION not VEC3" {
    const alloc = testing.allocator;
    const bin = try alloc.alloc(u8, 9 * 4);
    defer alloc.free(bin);
    @memset(bin, 0);
    const json =
        \\{
        \\ "buffers":[{"byteLength":36}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC2"}],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
        \\ "nodes":[{"mesh":0}],
        \\ "scenes":[{"nodes":[0]}]
        \\}
    ;
    const glb = try GlbBuilder.build(alloc, json, bin);
    defer alloc.free(glb);
    try testing.expectError(Error.UnsupportedPositionAccessor, parse(alloc, glb));
}

test "glb: TRS rotation quaternion 90deg about Y" {
    const alloc = testing.allocator;
    // Треугольник: v0(0,0,0) v1(1,0,0) v2(0,1,0).
    const verts = [9]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const indices = [_]u16{ 0, 1, 2 };
    const bin = try buildTriangleBin(alloc, verts, &indices);
    defer alloc.free(bin);

    // Кватернион 90° вокруг +Y: (x,y,z,w) = (0, sin45, 0, cos45).
    // Ожидаемый поворот: +X -> -Z, +Y -> +Y, +Z -> +X.
    // v0 -> (0,0,0); v1(1,0,0) -> (0,0,-1); v2(0,1,0) -> (0,1,0).
    const json =
        \\{
        \\ "buffers":[{"byteLength":42}],
        \\ "bufferViews":[
        \\   {"buffer":0,"byteOffset":0,"byteLength":36},
        \\   {"buffer":0,"byteOffset":36,"byteLength":6}
        \\ ],
        \\ "accessors":[
        \\   {"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
        \\   {"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}
        \\ ],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}],
        \\ "nodes":[{"mesh":0,"rotation":[0,0.70710678,0,0.70710678]}],
        \\ "scenes":[{"nodes":[0]}]
        \\}
    ;
    const glb = try GlbBuilder.build(alloc, json, bin);
    defer alloc.free(glb);

    var mesh = try parse(alloc, glb);
    defer mesh.deinit(alloc);

    try testing.expectEqual(@as(usize, 9), mesh.verts.len);
    const eps: f32 = 1e-5;
    // v0 (0,0,0)
    try testing.expectApproxEqAbs(@as(f32, 0), mesh.verts[0], eps);
    try testing.expectApproxEqAbs(@as(f32, 0), mesh.verts[1], eps);
    try testing.expectApproxEqAbs(@as(f32, 0), mesh.verts[2], eps);
    // v1 (1,0,0) -> (0,0,-1)
    try testing.expectApproxEqAbs(@as(f32, 0), mesh.verts[3], eps);
    try testing.expectApproxEqAbs(@as(f32, 0), mesh.verts[4], eps);
    try testing.expectApproxEqAbs(@as(f32, -1), mesh.verts[5], eps);
    // v2 (0,1,0) -> (0,1,0) (ось Y неизменна)
    try testing.expectApproxEqAbs(@as(f32, 0), mesh.verts[6], eps);
    try testing.expectApproxEqAbs(@as(f32, 1), mesh.verts[7], eps);
    try testing.expectApproxEqAbs(@as(f32, 0), mesh.verts[8], eps);
}

test "glb: interleaved POSITION with byteStride" {
    const alloc = testing.allocator;
    // Interleaved-буфер: на каждую вершину 8 f32 = 32 байта stride,
    // из них первые 3 f32 = POSITION, остальные 5 f32 = мусор (имитация NORMAL+UV).
    // 3 вершины: позиции (0,0,0) (1,0,0) (0,1,0).
    const positions = [3][3]f32{
        .{ 0, 0, 0 },
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
    };
    const stride_floats: usize = 8;
    const stride_bytes: usize = stride_floats * 4; // 32
    const pos_block: usize = stride_bytes * 3; // 96
    const idx_off: usize = pos_block; // индексы после позиций
    const indices = [_]u16{ 0, 1, 2 };
    const bin = try alloc.alloc(u8, pos_block + indices.len * 2);
    defer alloc.free(bin);
    @memset(bin, 0);
    // Заполняем interleaved: позиция в начале каждого strided-блока,
    // хвост (5 f32) — ненулевой мусор, чтобы поймать неверный stride.
    var v: usize = 0;
    while (v < 3) : (v += 1) {
        const base = v * stride_bytes;
        std.mem.writeInt(u32, bin[base + 0 ..][0..4], @bitCast(positions[v][0]), .little);
        std.mem.writeInt(u32, bin[base + 4 ..][0..4], @bitCast(positions[v][1]), .little);
        std.mem.writeInt(u32, bin[base + 8 ..][0..4], @bitCast(positions[v][2]), .little);
        // мусор в хвосте
        var f: usize = 3;
        while (f < stride_floats) : (f += 1) {
            std.mem.writeInt(u32, bin[base + f * 4 ..][0..4], @bitCast(@as(f32, 99.0)), .little);
        }
    }
    var w: usize = idx_off;
    for (indices) |ix| {
        std.mem.writeInt(u16, bin[w..][0..2], ix, .little);
        w += 2;
    }

    // bufferView0 покрывает interleaved-блок (96 байт) c byteStride=32.
    // bufferView1 — индексы (6 байт) без stride.
    const json =
        \\{
        \\ "buffers":[{"byteLength":102}],
        \\ "bufferViews":[
        \\   {"buffer":0,"byteOffset":0,"byteLength":96,"byteStride":32},
        \\   {"buffer":0,"byteOffset":96,"byteLength":6}
        \\ ],
        \\ "accessors":[
        \\   {"bufferView":0,"byteOffset":0,"componentType":5126,"count":3,"type":"VEC3"},
        \\   {"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}
        \\ ],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}],
        \\ "nodes":[{"mesh":0}],
        \\ "scenes":[{"nodes":[0]}]
        \\}
    ;
    const glb = try GlbBuilder.build(alloc, json, bin);
    defer alloc.free(glb);

    var mesh = try parse(alloc, glb);
    defer mesh.deinit(alloc);

    try testing.expectEqual(@as(usize, 9), mesh.verts.len);
    // Если stride учтён правильно — читаются ровно позиции, без мусора 99.0.
    try testing.expectApproxEqAbs(@as(f32, 0), mesh.verts[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), mesh.verts[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), mesh.verts[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), mesh.verts[3], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), mesh.verts[4], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), mesh.verts[5], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), mesh.verts[6], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), mesh.verts[7], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), mesh.verts[8], 1e-6);
}
