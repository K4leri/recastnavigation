const std = @import("std");
const math = @import("../math.zig");
const config = @import("config.zig");
const Context = @import("../context.zig").Context;
const Vec3 = math.Vec3;

/// Represents a span in a heightfield
pub const Span = struct {
    smin: u16, // Lower limit of span (using bit packing in original)
    smax: u16, // Upper limit of span
    area: u8, // Area ID
    next: ?*Span, // Next span higher up in column

    pub fn init(smin: u16, smax: u16, area: u8) Span {
        return .{
            .smin = smin,
            .smax = smax,
            .area = area,
            .next = null,
        };
    }
};

/// Memory pool for spans
pub const SpanPool = struct {
    items: [config.SPANS_PER_POOL]Span,
    next: ?*SpanPool,

    pub fn init() SpanPool {
        return .{
            .items = undefined,
            .next = null,
        };
    }
};

/// Dynamic heightfield representing obstructed space
pub const Heightfield = struct {
    width: i32, // Width in cell units
    height: i32, // Height in cell units
    bmin: Vec3, // Minimum bounds in world space
    bmax: Vec3, // Maximum bounds in world space
    cs: f32, // Cell size on xz-plane
    ch: f32, // Cell height
    spans: []?*Span, // Heightfield of spans (width*height)
    pools: ?*SpanPool, // Linked list of span pools
    freelist: ?*Span, // Next free span
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        width: i32,
        height: i32,
        bmin: Vec3,
        bmax: Vec3,
        cs: f32,
        ch: f32,
    ) !Self {
        const span_count = @as(usize, @intCast(width * height));
        const spans = try allocator.alloc(?*Span, span_count);
        @memset(spans, null);

        return Self{
            .width = width,
            .height = height,
            .bmin = bmin,
            .bmax = bmax,
            .cs = cs,
            .ch = ch,
            .spans = spans,
            .pools = null,
            .freelist = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free all span pools
        var pool = self.pools;
        while (pool) |p| {
            const next = p.next;
            self.allocator.destroy(p);
            pool = next;
        }

        self.allocator.free(self.spans);
        self.* = undefined;
    }

    pub fn allocSpan(self: *Self) !*Span {
        // If no free spans, allocate new pool
        if (self.freelist == null) {
            const pool = try self.allocator.create(SpanPool);
            pool.* = SpanPool.init();
            pool.next = self.pools;
            self.pools = pool;

            // Add all spans from pool to freelist
            self.freelist = &pool.items[0];
            for (0..config.SPANS_PER_POOL - 1) |i| {
                pool.items[i].next = &pool.items[i + 1];
            }
            pool.items[config.SPANS_PER_POOL - 1].next = null;
        }

        const span = self.freelist.?;
        self.freelist = span.next;
        span.* = Span.init(0, 0, 0);
        return span;
    }

    pub fn freeSpan(self: *Self, span: *Span) void {
        span.next = self.freelist;
        self.freelist = span;
    }

    pub fn getSpanCount(self: *const Self) usize {
        var count: usize = 0;
        for (self.spans) |span_ptr| {
            var s = span_ptr;
            while (s) |span| {
                count += 1;
                s = span.next;
            }
        }
        return count;
    }
};

/// Cell information for compact heightfield
pub const CompactCell = struct {
    index: u24, // Index to first span in column
    count: u8, // Number of spans in column

    pub fn init(index: u32, count: u8) CompactCell {
        return .{
            .index = @intCast(index),
            .count = count,
        };
    }
};

/// Span in compact heightfield
pub const CompactSpan = struct {
    y: u16, // Lower extent from heightfield base
    reg: u16, // Region ID (0 if not in region)
    con: u24, // Packed neighbor connection data
    h: u8, // Height of span

    pub fn init() CompactSpan {
        return .{
            .y = 0,
            .reg = 0,
            .con = 0,
            .h = 0,
        };
    }

    /// Sets neighbor connection for direction (0-3)
    pub fn setCon(self: *CompactSpan, direction: u2, neighbor_idx: u8) void {
        const shift: u5 = @as(u5, direction) * 6;
        const mask: u24 = @as(u24, 0x3f) << shift;
        self.con = (self.con & ~mask) | (@as(u24, neighbor_idx & 0x3f) << shift);
    }

    /// Gets neighbor connection for direction (0-3)
    pub fn getCon(self: *const CompactSpan, direction: u2) u8 {
        const shift: u5 = @as(u5, direction) * 6;
        return @intCast((self.con >> shift) & 0x3f);
    }
};

/// Compact static heightfield representing unobstructed space
pub const CompactHeightfield = struct {
    width: i32,
    height: i32,
    span_count: i32,
    walkable_height: i32,
    walkable_climb: i32,
    border_size: i32,
    max_distance: u16,
    max_regions: u16,
    bmin: Vec3,
    bmax: Vec3,
    cs: f32,
    ch: f32,
    cells: []CompactCell,
    spans: []CompactSpan,
    dist: []u16, // Border distance data
    areas: []u8, // Area ID data
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        width: i32,
        height: i32,
        span_count: i32,
        walkable_height: i32,
        walkable_climb: i32,
        bmin: Vec3,
        bmax: Vec3,
        cs: f32,
        ch: f32,
        border_size: i32,
    ) !Self {
        const span_ucount = @as(usize, @intCast(span_count));

        // Note: cells, spans, and areas will be allocated in buildCompactHeightfield()
        // to prevent memory leaks when they are replaced
        const cells: []CompactCell = &[_]CompactCell{};
        const spans: []CompactSpan = &[_]CompactSpan{};

        const dist = try allocator.alloc(u16, span_ucount);
        @memset(dist, 0);

        // areas will be allocated in buildCompactHeightfield()
        const areas: []u8 = &[_]u8{};

        return Self{
            .width = width,
            .height = height,
            .span_count = span_count,
            .walkable_height = walkable_height,
            .walkable_climb = walkable_climb,
            .border_size = border_size,
            .max_distance = 0,
            .max_regions = 0,
            .bmin = bmin,
            .bmax = bmax,
            .cs = cs,
            .ch = ch,
            .cells = cells,
            .spans = spans,
            .dist = dist,
            .areas = areas,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.spans);
        self.allocator.free(self.dist);
        self.allocator.free(self.areas);
        self.* = undefined;
    }
};

/// Direction offsets for neighbors
pub fn getDirOffsetX(direction: u2) i32 {
    const offsets = [4]i32{ -1, 0, 1, 0 };
    return offsets[direction];
}

pub fn getDirOffsetY(direction: u2) i32 {
    const offsets = [4]i32{ 0, 1, 0, -1 };
    return offsets[direction];
}

pub fn getDirForOffset(offset_x: i32, offset_z: i32) u2 {
    const dirs = [5]i32{ 3, 0, -1, 2, 1 };
    const idx = @as(usize, @intCast(((offset_z + 1) << 1) + offset_x));
    return @intCast(dirs[idx]);
}

// Tests
test "Heightfield creation" {
    const allocator = std.testing.allocator;

    // Setup test data matching C++ test
    const verts = [_]Vec3{
        Vec3.init(1.0, 2.0, 3.0),
        Vec3.init(0.0, 2.0, 6.0),
    };

    var bmin: Vec3 = undefined;
    var bmax: Vec3 = undefined;
    config.Config.calcBounds(&verts, &bmin, &bmax);

    const cell_size: f32 = 1.5;
    const cell_height: f32 = 2.0;

    var width: i32 = undefined;
    var height: i32 = undefined;
    config.Config.calcGridSize(bmin, bmax, cell_size, &width, &height);

    var hf = try Heightfield.init(
        allocator,
        width,
        height,
        bmin,
        bmax,
        cell_size,
        cell_height,
    );
    defer hf.deinit();

    // Verify all properties
    try std.testing.expectEqual(width, hf.width);
    try std.testing.expectEqual(height, hf.height);

    try std.testing.expectApproxEqAbs(bmin.x, hf.bmin.x, 0.0001);
    try std.testing.expectApproxEqAbs(bmin.y, hf.bmin.y, 0.0001);
    try std.testing.expectApproxEqAbs(bmin.z, hf.bmin.z, 0.0001);

    try std.testing.expectApproxEqAbs(bmax.x, hf.bmax.x, 0.0001);
    try std.testing.expectApproxEqAbs(bmax.y, hf.bmax.y, 0.0001);
    try std.testing.expectApproxEqAbs(bmax.z, hf.bmax.z, 0.0001);

    try std.testing.expectApproxEqAbs(cell_size, hf.cs, 0.0001);
    try std.testing.expectApproxEqAbs(cell_height, hf.ch, 0.0001);
}

test "CompactHeightfield creation" {
    const allocator = std.testing.allocator;

    var chf = try CompactHeightfield.init(
        allocator,
        100,
        100,
        1000,
        20,
        9,
        Vec3.init(0, 0, 0),
        Vec3.init(100, 10, 100),
        0.3,
        0.2,
        0,
    );
    defer chf.deinit();

    try std.testing.expectEqual(@as(i32, 100), chf.width);
    try std.testing.expectEqual(@as(i32, 1000), chf.span_count);
}
