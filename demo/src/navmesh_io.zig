//! Сохранение/загрузка dtNavMesh на диск — порт Sample::saveAll/loadAll (формат MSET).
//! Бинарный формат: header(magic/version/numTiles/params) + по тайлу (ref+size+bytes).

const std = @import("std");
const recast = @import("recast-nav");
const io_util = @import("io_util.zig");
const byteio = @import("persist/byteio.zig");

const dt = recast.detour;
const Vec3 = recast.math.Vec3;

const MAGIC: u32 = 0x4D534554; // 'MSET'
const VERSION: u32 = 1;

// LE byte-io shared (byteio.LeWriter). Previously these used std.mem.toBytes
// (HOST endian) — switching to forced .little is byte-identical on this LE x86_64
// host AND fixes the latent big-endian portability bug. See byteio.zig.
const putU32 = byteio.LeWriter.putU32;
const putI32 = byteio.LeWriter.putI32;
const putF32 = byteio.LeWriter.putF32;

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

/// Прочитать файл и построить navmesh. Тайлы получают free_data=true (navmesh владеет).
pub fn load(alloc: std.mem.Allocator, path: []const u8) !dt.NavMesh {
    const file = try io_util.readWholeFile(path, alloc);
    defer alloc.free(file);

    var r = byteio.LeReader.init(file);
    if (try r.readU32() != MAGIC) return error.WrongMagic;
    if (try r.readU32() != VERSION) return error.WrongVersion;
    const num_tiles = try r.readU32();

    var params = dt.NavMeshParams.init();
    params.orig = Vec3.init(try r.readF32(), try r.readF32(), try r.readF32());
    params.tile_width = try r.readF32();
    params.tile_height = try r.readF32();
    params.max_tiles = try r.readI32();
    params.max_polys = try r.readI32();

    var mesh = try dt.NavMesh.init(alloc, params);
    errdefer mesh.deinit();

    var i: u32 = 0;
    while (i < num_tiles) : (i += 1) {
        const ref = try r.readU32();
        const size = try r.readU32();
        if (ref == 0 or size == 0) break;
        const src = try r.readBytes(size);
        const data = try alloc.alloc(u8, size);
        @memcpy(data, src);
        _ = mesh.addTile(data, dt.TileFlags{ .free_data = true }, ref) catch {
            alloc.free(data);
        };
    }

    return mesh;
}
