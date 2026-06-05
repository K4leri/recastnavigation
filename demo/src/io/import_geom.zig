//! import_geom — единая точка загрузки входной геометрии (cluster D, D1).
//! Диспетч по расширению файла: `.obj` делегирует существующему
//! InputGeom.loadMesh (вершины/грани с веером), а `.stl`/`.ply`/`.gltf`/`.glb`
//! идут через чистые парсеры io/import_*.zig -> InputGeom.setMesh (verts/tris +
//! пересчёт bounds/normals). Это держит «куда складывать геометрию» в одном
//! месте и не ломает .obj-путь. Расширения матчатся БЕЗ учёта регистра
//! (ассеты бывают .OBJ/.GLB).
//!
//! Single entry point for loading input geometry: dispatch by file extension.

const std = @import("std");
const ig = @import("../input_geom.zig");
const io_util = @import("../io_util.zig");
const import_stl = @import("import_stl.zig");
const import_ply = @import("import_ply.zig");
const import_gltf = @import("import_gltf.zig");

/// Расширения, которые умеет грузить дропдаун входного меша / Import Geometry.
pub const supported_exts = [_][]const u8{ ".obj", ".stl", ".ply", ".gltf", ".glb" };

/// Регистронезависимое сравнение хвоста пути с расширением.
pub fn endsWithIgnoreCase(path: []const u8, ext: []const u8) bool {
    if (path.len < ext.len) return false;
    return std.ascii.eqlIgnoreCase(path[path.len - ext.len ..], ext);
}

/// true, если расширение пути — одно из поддерживаемых форматов геометрии.
pub fn isSupported(path: []const u8) bool {
    for (supported_exts) |e| {
        if (endsWithIgnoreCase(path, e)) return true;
    }
    return false;
}

/// Загрузить геометрию из `path` в `geom`, выбрав парсер по расширению.
/// `.obj` — встроенный загрузчик; остальные — io/import_*.zig. Ошибка парса/IO
/// пробрасывается вызывающему (он логирует в окно Log).
pub fn loadInto(geom: *ig.InputGeom, path: []const u8) !void {
    if (endsWithIgnoreCase(path, ".obj")) {
        return geom.loadMesh(path);
    }

    // Прочие форматы: читаем байты целиком, парсим в Mesh, переносим в geom.
    const bytes = try io_util.readWholeFile(path, geom.alloc);
    defer geom.alloc.free(bytes);

    if (endsWithIgnoreCase(path, ".stl")) {
        var m = try import_stl.parse(geom.alloc, bytes);
        defer m.deinit(geom.alloc);
        try geom.setMesh(m.verts, m.tris);
    } else if (endsWithIgnoreCase(path, ".ply")) {
        var m = try import_ply.parse(geom.alloc, bytes);
        defer m.deinit(geom.alloc);
        try geom.setMesh(m.verts, m.tris);
    } else if (endsWithIgnoreCase(path, ".gltf") or endsWithIgnoreCase(path, ".glb")) {
        var m = try import_gltf.parse(geom.alloc, bytes);
        defer m.deinit(geom.alloc);
        try geom.setMesh(m.verts, m.tris);
    } else {
        return error.UnsupportedMeshFormat;
    }
}

test "endsWithIgnoreCase / isSupported" {
    try std.testing.expect(endsWithIgnoreCase("a/b/c.GLB", ".glb"));
    try std.testing.expect(endsWithIgnoreCase("scene.obj", ".obj"));
    try std.testing.expect(!endsWithIgnoreCase("scene.objx", ".obj"));
    try std.testing.expect(isSupported("dungeon.ply"));
    try std.testing.expect(isSupported("MODEL.STL"));
    try std.testing.expect(!isSupported("notes.txt"));
}
