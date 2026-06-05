//! Файловые утилиты демо (zig 0.16 std.Io.Dir) + таймер производительности.
//! Аналог FileIO + PerfTimer + scanDirectory из RecastDemo.

const std = @import("std");

/// Читает файл целиком в owned-буфер.
pub fn readWholeFile(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

/// Пишет данные в файл (создаёт/перезаписывает).
pub fn writeWholeFile(path: []const u8, data: []const u8, allocator: std.mem.Allocator) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// Резолвит каталог ассетов demo. Ищет `name` сначала рядом с исполняемым файлом
/// (<exeDir>/name — для распространяемого standalone), затем в cwd и вверх по дереву
/// (запуск `zig-out/bin/recast_demo.exe` из repo root → подъём найдёт `test_data`).
/// Возвращает owned-путь (вызывающий освобождает); фолбэк — дубликат `name`
/// (cwd-относительный, прежнее поведение).
pub fn resolveAssetDir(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dirExists = struct {
        fn f(io_: std.Io, path: []const u8) bool {
            var d = std.Io.Dir.cwd().openDir(io_, path, .{}) catch return false;
            d.close(io_);
            return true;
        }
    }.f;

    // 1) Рядом с exe: <exeDir>/<name> — приоритет для установленного/распространяемого билда.
    var exe_buf: [4096]u8 = undefined;
    if (std.process.executableDirPath(io, &exe_buf)) |n| {
        const cand = try std.fs.path.join(allocator, &.{ exe_buf[0..n], name });
        if (dirExists(io, cand)) return cand;
        allocator.free(cand);
    } else |_| {}

    // 2) cwd и вверх по дереву (repo root из zig-out/bin = ../.. ; из zig-out = ..).
    const prefixes = [_][]const u8{ "", "..", "../..", "../../.." };
    for (prefixes) |pre| {
        const cand = if (pre.len == 0)
            try allocator.dupe(u8, name)
        else
            try std.fs.path.join(allocator, &.{ pre, name });
        if (dirExists(io, cand)) return cand;
        allocator.free(cand);
    }

    return allocator.dupe(u8, name); // фолбэк: прежнее cwd-относительное поведение
}

/// Список файлов в каталоге с заданным расширением (отсортированный).
/// Возвращает owned-срез owned-строк (вызывающий освобождает каждую и срез).
pub fn scanDirectory(allocator: std.mem.Allocator, dir_path: []const u8, ext: []const u8) ![][]u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var list = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit();
    }

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        return list.toOwnedSlice(); // нет каталога -> пустой список
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ext)) continue;
        try list.append(try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]u8, list.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    return list.toOwnedSlice();
}

/// Как scanDirectory, но матчит ЛЮБОЕ из расширений `exts` (регистронезависимо).
/// Один проход по каталогу; результат отсортирован по имени. Используется для
/// дропдауна входного меша (cluster D, D1: .obj/.stl/.ply/.gltf/.glb).
pub fn scanDirectoryAny(allocator: std.mem.Allocator, dir_path: []const u8, exts: []const []const u8) ![][]u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var list = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit();
    }

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        return list.toOwnedSlice();
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        var ok = false;
        for (exts) |ext| {
            if (entry.name.len >= ext.len and
                std.ascii.eqlIgnoreCase(entry.name[entry.name.len - ext.len ..], ext))
            {
                ok = true;
                break;
            }
        }
        if (!ok) continue;
        try list.append(try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]u8, list.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    return list.toOwnedSlice();
}

/// Высокоточный таймер (аналог PerfTimer). zig 0.16: std.time.Timer удалён,
/// используем монотонные часы std.Io.Clock(.awake).
pub const PerfTimer = struct {
    start_ns: i128,

    pub fn start() PerfTimer {
        return .{ .start_ns = nowNs() };
    }

    /// Прошедшее время в миллисекундах с момента start/reset.
    pub fn readMs(self: *PerfTimer) f32 {
        const d: f64 = @floatFromInt(nowNs() - self.start_ns);
        return @floatCast(d / 1_000_000.0);
    }

    pub fn reset(self: *PerfTimer) void {
        self.start_ns = nowNs();
    }

    fn nowNs() i128 {
        var t: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        defer t.deinit();
        return @intCast(std.Io.Clock.now(.awake, t.io()).nanoseconds);
    }
};
