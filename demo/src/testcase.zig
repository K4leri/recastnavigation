//! Загрузка и визуализация тест-кейсов — порт RecastDemo/TestCase.cpp.
//! Формат строк: 's <sample>', 'f <geom>', 'pf x y z x y z incHex excHex', 'rc ...'.

const std = @import("std");
const recast = @import("recast-nav");
const io_util = @import("io_util.zig");

const dt = recast.detour;
const dbg = recast.debug;

const MAX_POLYS = 256;

pub const TestType = enum { pathfind, raycast };

pub const Test = struct {
    typ: TestType,
    spos: [3]f32,
    epos: [3]f32,
    include: u16,
    exclude: u16,
    // кешированный результат (считается один раз)
    nstraight: usize = 0,
    straight: [MAX_POLYS * 3]f32 = undefined,
    ray_hit: [3]f32 = .{ 0, 0, 0 },
    ray_miss: bool = false,
    valid: bool = false,
    time_ms: f32 = 0,
};

pub const TestCase = struct {
    alloc: std.mem.Allocator,
    sample_name: [64]u8 = [_]u8{0} ** 64,
    geom_name: [64]u8 = [_]u8{0} ** 64,
    tests: std.array_list.Managed(Test),
    computed: bool = false,
    total_ms: f32 = 0,
    n_ok: usize = 0,

    pub fn deinit(self: *TestCase) void {
        self.tests.deinit();
    }

    pub fn sampleName(self: *const TestCase) []const u8 {
        return std.mem.sliceTo(&self.sample_name, 0);
    }
    pub fn geomName(self: *const TestCase) []const u8 {
        return std.mem.sliceTo(&self.geom_name, 0);
    }

    /// Распарсить тест-кейс из файла.
    pub fn load(alloc: std.mem.Allocator, path: []const u8) !TestCase {
        const buf = try io_util.readWholeFile(path, alloc);
        defer alloc.free(buf);

        var tc = TestCase{ .alloc = alloc, .tests = std.array_list.Managed(Test).init(alloc) };
        errdefer tc.tests.deinit();

        var it = std.mem.tokenizeAny(u8, buf, "\r\n");
        while (it.next()) |line| {
            if (line.len < 2) continue;
            if (line[0] == 's') {
                copyName(&tc.sample_name, std.mem.trim(u8, line[1..], " \t"));
            } else if (line[0] == 'f') {
                copyName(&tc.geom_name, std.mem.trim(u8, line[1..], " \t"));
            } else if (line[0] == 'p' and line[1] == 'f') {
                if (parseTest(.pathfind, line[2..])) |t| try tc.tests.append(t);
            } else if (line[0] == 'r' and line[1] == 'c') {
                if (parseTest(.raycast, line[2..])) |t| try tc.tests.append(t);
            }
        }
        return tc;
    }

    /// Посчитать пути по всем тестам один раз (кеш). Идемпотентно.
    pub fn compute(self: *TestCase, query: *dt.NavMeshQuery) void {
        const ext = [3]f32{ 2, 4, 2 };
        self.total_ms = 0;
        self.n_ok = 0;
        for (self.tests.items) |*t| {
            t.valid = false;
            t.nstraight = 0;
            var timer = io_util.PerfTimer.start();
            computeOne(query, t, ext);
            t.time_ms = timer.readMs();
            self.total_ms += t.time_ms;
            if (t.valid) self.n_ok += 1;
        }
        self.computed = true;
    }

    fn computeOne(query: *dt.NavMeshQuery, t: *Test, ext: [3]f32) void {
        var filter = dt.QueryFilter.init();
        filter.setIncludeFlags(t.include);
        filter.setExcludeFlags(t.exclude);

        var sref: dt.PolyRef = 0;
        var eref: dt.PolyRef = 0;
        var snap: [3]f32 = undefined;
        _ = query.findNearestPoly(&t.spos, &ext, &filter, &sref, &snap) catch return;
        _ = query.findNearestPoly(&t.epos, &ext, &filter, &eref, &snap) catch return;

        if (t.typ == .pathfind) {
            if (sref == 0 or eref == 0) return;
            var polys: [MAX_POLYS]dt.PolyRef = undefined;
            var n: usize = 0;
            _ = query.findPath(sref, eref, &t.spos, &t.epos, &filter, polys[0..], &n) catch return;
            if (n == 0) return;
            var sflags: [MAX_POLYS]u8 = undefined;
            var srefs: [MAX_POLYS]dt.PolyRef = undefined;
            var ns: usize = 0;
            _ = query.findStraightPath(&t.spos, &t.epos, polys[0..n], t.straight[0..], sflags[0..], srefs[0..], &ns, 0) catch return;
            t.nstraight = ns;
            t.valid = true;
        } else {
            if (sref == 0) return;
            var polys: [MAX_POLYS]dt.PolyRef = undefined;
            var hit = dt.RaycastHit.init(polys[0..]);
            _ = query.raycast(sref, &t.spos, &t.epos, &filter, 0, &hit, 0) catch return;
            const tt = @min(hit.t, 1.0);
            t.ray_hit = .{
                t.spos[0] + (t.epos[0] - t.spos[0]) * tt,
                t.spos[1] + (t.epos[1] - t.spos[1]) * tt,
                t.spos[2] + (t.epos[2] - t.spos[2]) * tt,
            };
            t.ray_miss = hit.t > 1.0;
            t.valid = true;
        }
    }

    /// Нарисовать кешированные результаты (без пересчёта).
    pub fn render(self: *TestCase, dd: dbg.DebugDraw) void {
        for (self.tests.items) |*t| {
            drawMarker(dd, t.spos, dbg.rgba(64, 255, 64, 255));
            drawMarker(dd, t.epos, dbg.rgba(255, 64, 64, 255));
            if (!t.valid) continue;
            if (t.typ == .pathfind) {
                if (t.nstraight < 2) continue;
                const col = dbg.rgba(64, 160, 255, 220);
                dd.begin(.lines, 2.0);
                var i: usize = 0;
                while (i + 1 < t.nstraight) : (i += 1) {
                    dd.vertexXYZ(t.straight[i * 3], t.straight[i * 3 + 1] + 0.1, t.straight[i * 3 + 2], col);
                    dd.vertexXYZ(t.straight[(i + 1) * 3], t.straight[(i + 1) * 3 + 1] + 0.1, t.straight[(i + 1) * 3 + 2], col);
                }
                dd.end();
            } else {
                const col = if (t.ray_miss) dbg.rgba(64, 255, 64, 255) else dbg.rgba(255, 64, 64, 255);
                dd.begin(.lines, 2.0);
                dd.vertexXYZ(t.spos[0], t.spos[1] + 0.1, t.spos[2], col);
                dd.vertexXYZ(t.ray_hit[0], t.ray_hit[1] + 0.1, t.ray_hit[2], col);
                dd.end();
            }
        }
    }
};

fn copyName(dst: *[64]u8, src: []const u8) void {
    const n = @min(src.len, dst.len - 1);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}

fn parseTest(typ: TestType, rest: []const u8) ?Test {
    var it = std.mem.tokenizeAny(u8, rest, " \t");
    var f: [6]f32 = undefined;
    for (0..6) |i| {
        const tok = it.next() orelse return null;
        f[i] = std.fmt.parseFloat(f32, tok) catch return null;
    }
    const inc = parseHex(it.next() orelse "0xffff");
    const exc = parseHex(it.next() orelse "0x0");
    return .{
        .typ = typ,
        .spos = .{ f[0], f[1], f[2] },
        .epos = .{ f[3], f[4], f[5] },
        .include = inc,
        .exclude = exc,
    };
}

fn parseHex(tok: []const u8) u16 {
    const s = if (std.mem.startsWith(u8, tok, "0x") or std.mem.startsWith(u8, tok, "0X")) tok[2..] else tok;
    return std.fmt.parseInt(u16, s, 16) catch 0xffff;
}

fn drawMarker(dd: dbg.DebugDraw, p: [3]f32, col: u32) void {
    dd.begin(.lines, 1.0);
    dd.vertexXYZ(p[0] - 0.4, p[1] + 0.1, p[2], col);
    dd.vertexXYZ(p[0] + 0.4, p[1] + 0.1, p[2], col);
    dd.vertexXYZ(p[0], p[1] + 0.1, p[2] - 0.4, col);
    dd.vertexXYZ(p[0], p[1] + 0.1, p[2] + 0.4, col);
    dd.end();
}
