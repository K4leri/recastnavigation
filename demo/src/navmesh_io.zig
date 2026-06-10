//! Сохранение/загрузка dtNavMesh на диск — порт Sample::saveAll/loadAll (формат MSET).
//! Бинарный формат: header(magic/version/numTiles/params) + по тайлу (ref+size+bytes).

const std = @import("std");
const recast = @import("recast-nav");
const io_util = @import("io_util.zig");

const dt = recast.detour;
const Vec3 = recast.math.Vec3;

const MAGIC: u32 = 0x4D534554; // 'MSET'
const VERSION: u32 = 1;

fn putU32(buf: *std.array_list.Managed(u8), v: u32) !void {
    try buf.appendSlice(&std.mem.toBytes(v));
}
fn putI32(buf: *std.array_list.Managed(u8), v: i32) !void {
    try buf.appendSlice(&std.mem.toBytes(v));
}
fn putF32(buf: *std.array_list.Managed(u8), v: f32) !void {
    try buf.appendSlice(&std.mem.toBytes(v));
}

/// Сериализовать navmesh и записать в файл.
pub fn save(alloc: std.mem.Allocator, path: []const u8, mesh: *const dt.NavMesh) !void {
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();

    // подсчёт валидных тайлов
    var num_tiles: u32 = 0;
    for (mesh.tiles) |*t| {
        if (t.header != null and t.data_size > 0) num_tiles += 1;
    }

    try putU32(&buf, MAGIC);
    try putU32(&buf, VERSION);
    try putU32(&buf, num_tiles);
    // params
    try putF32(&buf, mesh.params.orig.x);
    try putF32(&buf, mesh.params.orig.y);
    try putF32(&buf, mesh.params.orig.z);
    try putF32(&buf, mesh.params.tile_width);
    try putF32(&buf, mesh.params.tile_height);
    try putI32(&buf, mesh.params.max_tiles);
    try putI32(&buf, mesh.params.max_polys);

    // тайлы
    for (mesh.tiles) |*t| {
        if (t.header == null or t.data_size == 0) continue;
        const ref = mesh.getTileRef(t);
        try putU32(&buf, ref);
        try putU32(&buf, @intCast(t.data_size));
        try buf.appendSlice(t.data[0..t.data_size]);
    }

    try io_util.writeWholeFile(path, buf.items, alloc);
}

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn u32_(self: *Reader) !u32 {
        if (self.pos + 4 > self.data.len) return error.Truncated;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }
    fn i32_(self: *Reader) !i32 {
        return @bitCast(try self.u32_());
    }
    fn f32_(self: *Reader) !f32 {
        return @bitCast(try self.u32_());
    }
    fn bytes(self: *Reader, n: usize) ![]const u8 {
        if (self.pos + n > self.data.len) return error.Truncated;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
};

/// Прочитать файл и построить navmesh. Тайлы получают free_data=true (navmesh владеет).
pub fn load(alloc: std.mem.Allocator, path: []const u8) !dt.NavMesh {
    const file = try io_util.readWholeFile(path, alloc);
    defer alloc.free(file);

    var r = Reader{ .data = file };
    if (try r.u32_() != MAGIC) return error.WrongMagic;
    if (try r.u32_() != VERSION) return error.WrongVersion;
    const num_tiles = try r.u32_();

    var params = dt.NavMeshParams.init();
    params.orig = Vec3.init(try r.f32_(), try r.f32_(), try r.f32_());
    params.tile_width = try r.f32_();
    params.tile_height = try r.f32_();
    params.max_tiles = try r.i32_();
    params.max_polys = try r.i32_();

    var mesh = try dt.NavMesh.init(alloc, params);
    errdefer mesh.deinit();

    var i: u32 = 0;
    while (i < num_tiles) : (i += 1) {
        const ref = try r.u32_();
        const size = try r.u32_();
        if (ref == 0 or size == 0) break;
        const src = try r.bytes(size);
        const data = try alloc.alloc(u8, size);
        @memcpy(data, src);
        _ = mesh.addTile(data, dt.TileFlags{ .free_data = true }, ref) catch {
            alloc.free(data);
        };
    }

    return mesh;
}
