const std = @import("std");
const math = @import("../math.zig");

/// Spatial proximity grid for fast spatial queries
/// Uses hash grid with chaining for collision resolution
pub const ProximityGrid = struct {
    const Item = struct {
        id: u16,
        x: i16,
        y: i16,
        next: u16,
    };

    cell_size: f32,
    inv_cell_size: f32,
    pool: []Item,
    pool_head: usize,
    pool_size: usize,
    buckets: []u16,
    buckets_size: usize,
    bounds: [4]i32,
    allocator: std.mem.Allocator,

    const Self = @This();
    const INVALID_ID: u16 = 0xffff;

    /// Initialize proximity grid
    pub fn init(allocator: std.mem.Allocator, pool_size: usize, cell_size: f32) !Self {
        if (pool_size == 0 or cell_size <= 0.0) {
            return error.InvalidParam;
        }

        const buckets_size = math.nextPow2(@intCast(pool_size));
        const buckets = try allocator.alloc(u16, buckets_size);
        errdefer allocator.free(buckets);

        const pool = try allocator.alloc(Item, pool_size);
        errdefer allocator.free(pool);

        var grid = Self{
            .cell_size = cell_size,
            .inv_cell_size = 1.0 / cell_size,
            .pool = pool,
            .pool_head = 0,
            .pool_size = pool_size,
            .buckets = buckets,
            .buckets_size = buckets_size,
            .bounds = [4]i32{ 0, 0, 0, 0 },
            .allocator = allocator,
        };

        grid.clear();
        return grid;
    }

    /// Free proximity grid resources
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buckets);
        self.allocator.free(self.pool);
    }

    /// Clear the grid
    pub fn clear(self: *Self) void {
        @memset(self.buckets, INVALID_ID);
        self.pool_head = 0;
        self.bounds[0] = 0xffff;
        self.bounds[1] = 0xffff;
        self.bounds[2] = -0xffff;
        self.bounds[3] = -0xffff;
    }

    /// Add an item to the grid
    pub fn addItem(self: *Self, id: u16, minx: f32, miny: f32, maxx: f32, maxy: f32) void {
        const iminx: i32 = @intFromFloat(@floor(minx * self.inv_cell_size));
        const iminy: i32 = @intFromFloat(@floor(miny * self.inv_cell_size));
        const imaxx: i32 = @intFromFloat(@floor(maxx * self.inv_cell_size));
        const imaxy: i32 = @intFromFloat(@floor(maxy * self.inv_cell_size));

        self.bounds[0] = @min(self.bounds[0], iminx);
        self.bounds[1] = @min(self.bounds[1], iminy);
        self.bounds[2] = @max(self.bounds[2], imaxx);
        self.bounds[3] = @max(self.bounds[3], imaxy);

        var y = iminy;
        while (y <= imaxy) : (y += 1) {
            var x = iminx;
            while (x <= imaxx) : (x += 1) {
                if (self.pool_head < self.pool_size) {
                    const h = hashPos2(x, y, @intCast(self.buckets_size));
                    const idx: u16 = @intCast(self.pool_head);
                    self.pool_head += 1;

                    self.pool[idx].x = @intCast(x);
                    self.pool[idx].y = @intCast(y);
                    self.pool[idx].id = id;
                    self.pool[idx].next = self.buckets[h];
                    self.buckets[h] = idx;
                }
            }
        }
    }

    /// Query items in the given area
    pub fn queryItems(
        self: *const Self,
        minx: f32,
        miny: f32,
        maxx: f32,
        maxy: f32,
        ids: []u16,
    ) usize {
        const iminx: i32 = @intFromFloat(@floor(minx * self.inv_cell_size));
        const iminy: i32 = @intFromFloat(@floor(miny * self.inv_cell_size));
        const imaxx: i32 = @intFromFloat(@floor(maxx * self.inv_cell_size));
        const imaxy: i32 = @intFromFloat(@floor(maxy * self.inv_cell_size));

        var n: usize = 0;

        var y = iminy;
        while (y <= imaxy) : (y += 1) {
            var x = iminx;
            while (x <= imaxx) : (x += 1) {
                const h = hashPos2(x, y, @intCast(self.buckets_size));
                var idx = self.buckets[h];

                while (idx != INVALID_ID) {
                    const item = &self.pool[idx];
                    if (item.x == x and item.y == y) {
                        // Check if the id exists already
                        var found = false;
                        for (ids[0..n]) |existing_id| {
                            if (existing_id == item.id) {
                                found = true;
                                break;
                            }
                        }

                        // Item not found, add it
                        if (!found) {
                            if (n >= ids.len) {
                                return n;
                            }
                            ids[n] = item.id;
                            n += 1;
                        }
                    }
                    idx = item.next;
                }
            }
        }

        return n;
    }

    /// Get the number of items at a specific grid cell
    pub fn getItemCountAt(self: *const Self, x: i32, y: i32) usize {
        var n: usize = 0;

        const h = hashPos2(x, y, @intCast(self.buckets_size));
        var idx = self.buckets[h];

        while (idx != INVALID_ID) {
            const item = &self.pool[idx];
            if (item.x == x and item.y == y) {
                n += 1;
            }
            idx = item.next;
        }

        return n;
    }

    /// Get the grid bounds
    pub fn getBounds(self: *const Self) *const [4]i32 {
        return &self.bounds;
    }

    /// Get the cell size
    pub fn getCellSize(self: *const Self) f32 {
        return self.cell_size;
    }
};

/// Hash function for 2D position
inline fn hashPos2(x: i32, y: i32, n: i32) usize {
    const ux: u32 = @bitCast(x);
    const uy: u32 = @bitCast(y);
    const un: u32 = @bitCast(n);
    return @intCast((ux *% 73856093) ^ (uy *% 19349663) & (un - 1));
}

test "ProximityGrid basic" {
    const allocator = std.testing.allocator;

    var grid = try ProximityGrid.init(allocator, 128, 1.0);
    defer grid.deinit();

    // Add some items
    grid.addItem(0, 0.0, 0.0, 1.0, 1.0);
    grid.addItem(1, 2.0, 2.0, 3.0, 3.0);
    grid.addItem(2, 0.5, 0.5, 1.5, 1.5);

    // Query items
    var ids: [10]u16 = undefined;
    const n = grid.queryItems(0.0, 0.0, 2.0, 2.0, &ids);

    try std.testing.expect(n >= 2); // Should find at least items 0 and 2
    try std.testing.expectEqual(@as(f32, 1.0), grid.getCellSize());
}

test "ProximityGrid clear" {
    const allocator = std.testing.allocator;

    var grid = try ProximityGrid.init(allocator, 64, 0.5);
    defer grid.deinit();

    grid.addItem(0, 0.0, 0.0, 1.0, 1.0);
    grid.clear();

    var ids: [10]u16 = undefined;
    const n = grid.queryItems(0.0, 0.0, 2.0, 2.0, &ids);

    try std.testing.expectEqual(@as(usize, 0), n);
}
