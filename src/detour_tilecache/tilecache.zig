const std = @import("std");
const math = @import("../math.zig");
const common = @import("../detour/common.zig");
const NavMesh = @import("../detour/navmesh.zig").NavMesh;
const NavMeshParams = @import("../detour/navmesh.zig").NavMeshParams;
const NavMeshCreateParams = @import("../detour/builder.zig").NavMeshCreateParams;
const detour_builder = @import("../detour/builder.zig");
const Status = @import("../detour/common.zig").Status;
const builder_mod = @import("builder.zig");

pub const TileCacheLayerHeader = builder_mod.TileCacheLayerHeader;
pub const TileCacheLayer = builder_mod.TileCacheLayer;
pub const TileCacheCompressor = builder_mod.TileCacheCompressor;
pub const TileCacheContourSet = builder_mod.TileCacheContourSet;
pub const TileCachePolyMesh = builder_mod.TileCachePolyMesh;

// Type aliases
pub const ObstacleRef = u32;
pub const CompressedTileRef = u32;

// Constants
pub const MAX_TOUCHED_TILES: usize = 8;
const MAX_REQUESTS: usize = 64;
const MAX_UPDATE: usize = 64;

/// Flags for addTile
pub const CompressedTileFlags = packed struct(u8) {
    free_data: bool = false, // TileCache owns the tile memory and should free it
    _padding: u7 = 0,
};

/// Compressed tile
pub const CompressedTile = struct {
    salt: u32, // Counter describing modifications to the tile
    header: ?*TileCacheLayerHeader, // Tile header
    compressed: []u8, // Compressed data
    data: []u8, // Full data buffer (header + compressed)
    flags: CompressedTileFlags, // Tile flags
    next: ?*CompressedTile, // Next tile in freelist or hash chain
};

/// Obstacle state
pub const ObstacleState = enum(u8) {
    empty,
    processing,
    processed,
    removing,
};

/// Obstacle type
pub const ObstacleType = enum(u8) {
    cylinder,
    box, // AABB
    oriented_box, // OBB
};

/// Cylinder obstacle
pub const ObstacleCylinder = struct {
    pos: [3]f32,
    radius: f32,
    height: f32,
};

/// Box obstacle (AABB)
pub const ObstacleBox = struct {
    bmin: [3]f32,
    bmax: [3]f32,
};

/// Oriented box obstacle (OBB)
pub const ObstacleOrientedBox = struct {
    center: [3]f32,
    half_extents: [3]f32,
    rot_aux: [2]f32, // {cos(0.5*angle)*sin(-0.5*angle), cos(0.5*angle)*cos(0.5*angle) - 0.5}
};

/// Tile cache obstacle
pub const TileCacheObstacle = struct {
    /// Obstacle shape (union)
    shape: union(ObstacleType) {
        cylinder: ObstacleCylinder,
        box: ObstacleBox,
        oriented_box: ObstacleOrientedBox,
    },

    touched: [MAX_TOUCHED_TILES]CompressedTileRef, // Tiles touched by obstacle
    pending: [MAX_TOUCHED_TILES]CompressedTileRef, // Tiles pending rebuild
    salt: u16, // Salt for ref versioning
    state: ObstacleState, // Current state
    ntouched: u8, // Number of touched tiles
    npending: u8, // Number of pending tiles
    next: ?*TileCacheObstacle, // Next in freelist
};

/// Tile cache parameters
pub const TileCacheParams = struct {
    orig: [3]f32, // Origin of the tile cache
    cs: f32, // Cell size
    ch: f32, // Cell height
    width: i32, // Tile width
    height: i32, // Tile height
    walkable_height: f32, // Agent height
    walkable_radius: f32, // Agent radius
    walkable_climb: f32, // Agent max climb
    max_simplification_error: f32, // Max contour simplification error
    max_tiles: i32, // Max number of tiles
    max_obstacles: i32, // Max number of obstacles
};

/// Mesh process callback interface
pub const TileCacheMeshProcess = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        process: *const fn (
            ptr: *anyopaque,
            params: *anyopaque, // NavMeshCreateParams
            poly_areas: []u8,
            poly_flags: []u16,
        ) void,
    };

    pub fn process(
        self: *TileCacheMeshProcess,
        params: *anyopaque,
        poly_areas: []u8,
        poly_flags: []u16,
    ) void {
        self.vtable.process(self.ptr, params, poly_areas, poly_flags);
    }
};

/// Obstacle request action
const ObstacleRequestAction = enum(i32) {
    add,
    remove,
};

/// Obstacle request
const ObstacleRequest = struct {
    action: ObstacleRequestAction,
    ref: ObstacleRef,
};

/// Tile cache manager
pub const TileCache = struct {
    // Hash lookup
    tile_lut_size: usize, // Tile hash lookup size (must be pot)
    tile_lut_mask: usize, // Tile hash lookup mask
    pos_lookup: []?*CompressedTile, // Tile hash lookup

    // Tile storage
    tiles: []CompressedTile, // Tile array
    next_free_tile: ?*CompressedTile, // Freelist of tiles

    // ID generation
    salt_bits: u32, // Number of salt bits in tile ID
    tile_bits: u32, // Number of tile bits in tile ID

    // Parameters and callbacks
    params: TileCacheParams,
    comp: ?*TileCacheCompressor,
    tmproc: ?*TileCacheMeshProcess,

    // Obstacle storage
    obstacles: []TileCacheObstacle, // Obstacle array
    next_free_obstacle: ?*TileCacheObstacle, // Freelist of obstacles

    // Request queue
    reqs: [MAX_REQUESTS]ObstacleRequest, // Obstacle requests
    nreqs: usize, // Number of requests

    // Update queue
    update_queue: [MAX_UPDATE]CompressedTileRef, // Tiles to update
    nupdate: usize, // Number of tiles to update

    // Memory
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize tile cache
    pub fn init(
        allocator: std.mem.Allocator,
        params: *const TileCacheParams,
        comp: ?*TileCacheCompressor,
        tmproc: ?*TileCacheMeshProcess,
    ) !Self {
        var self = Self{
            .tile_lut_size = 0,
            .tile_lut_mask = 0,
            .pos_lookup = &[_]?*CompressedTile{},
            .tiles = &[_]CompressedTile{},
            .next_free_tile = null,
            .salt_bits = 0,
            .tile_bits = 0,
            .params = params.*,
            .comp = comp,
            .tmproc = tmproc,
            .obstacles = &[_]TileCacheObstacle{},
            .next_free_obstacle = null,
            .reqs = undefined,
            .nreqs = 0,
            .update_queue = undefined,
            .nupdate = 0,
            .allocator = allocator,
        };

        // Allocate obstacles
        const max_obstacles = @as(usize, @intCast(params.max_obstacles));
        self.obstacles = try allocator.alloc(TileCacheObstacle, max_obstacles);
        errdefer allocator.free(self.obstacles);

        @memset(self.obstacles, TileCacheObstacle{
            .shape = .{ .cylinder = .{
                .pos = .{ 0, 0, 0 },
                .radius = 0,
                .height = 0,
            } },
            .touched = [_]CompressedTileRef{0} ** MAX_TOUCHED_TILES,
            .pending = [_]CompressedTileRef{0} ** MAX_TOUCHED_TILES,
            .salt = 1,
            .state = .empty,
            .ntouched = 0,
            .npending = 0,
            .next = null,
        });

        // Build obstacle freelist (backwards to maintain order)
        self.next_free_obstacle = null;
        var i: usize = max_obstacles;
        while (i > 0) {
            i -= 1;
            self.obstacles[i].salt = 1;
            self.obstacles[i].next = self.next_free_obstacle;
            self.next_free_obstacle = &self.obstacles[i];
        }

        // Initialize tiles
        const max_tiles = @as(usize, @intCast(params.max_tiles));
        self.tile_lut_size = math.nextPow2(@as(u32, @intCast(max_tiles / 4)));
        if (self.tile_lut_size == 0) self.tile_lut_size = 1;
        self.tile_lut_mask = self.tile_lut_size - 1;

        self.tiles = try allocator.alloc(CompressedTile, max_tiles);
        errdefer allocator.free(self.tiles);

        self.pos_lookup = try allocator.alloc(?*CompressedTile, self.tile_lut_size);
        errdefer allocator.free(self.pos_lookup);

        @memset(self.tiles, CompressedTile{
            .salt = 1,
            .header = null,
            .compressed = &[_]u8{},
            .data = &[_]u8{},
            .flags = .{},
            .next = null,
        });
        @memset(self.pos_lookup, null);

        // Build tile freelist (backwards to maintain order)
        self.next_free_tile = null;
        i = max_tiles;
        while (i > 0) {
            i -= 1;
            self.tiles[i].salt = 1;
            self.tiles[i].next = self.next_free_tile;
            self.next_free_tile = &self.tiles[i];
        }

        // Initialize ID generator values
        self.tile_bits = @intCast(math.ilog2(math.nextPow2(@as(u32, @intCast(max_tiles)))));
        // Only allow 31 salt bits (overflow prevention)
        self.salt_bits = @min(31, 32 - self.tile_bits);

        if (self.salt_bits < 10) {
            return error.InvalidParams;
        }

        return self;
    }

    /// Deinitialize tile cache
    pub fn deinit(self: *Self) void {
        // Free tile data if owned
        for (self.tiles) |*tile| {
            if (tile.flags.free_data and tile.data.len > 0) {
                self.allocator.free(tile.data);
            }
        }

        self.allocator.free(self.obstacles);
        self.allocator.free(self.pos_lookup);
        self.allocator.free(self.tiles);
    }

    /// Get compressor
    pub fn getCompressor(self: *Self) ?*TileCacheCompressor {
        return self.comp;
    }

    /// Get parameters
    pub fn getParams(self: *const Self) *const TileCacheParams {
        return &self.params;
    }

    /// Get tile count
    pub fn getTileCount(self: *const Self) usize {
        return @intCast(self.params.max_tiles);
    }

    /// Get tile by index
    pub fn getTile(self: *const Self, i: usize) *const CompressedTile {
        return &self.tiles[i];
    }

    /// Get obstacle count
    pub fn getObstacleCount(self: *const Self) usize {
        return @intCast(self.params.max_obstacles);
    }

    /// Get obstacle by index
    pub fn getObstacle(self: *const Self, i: usize) *const TileCacheObstacle {
        return &self.obstacles[i];
    }

    /// Encode tile ID from salt and index
    pub fn encodeTileId(self: *const Self, salt: u32, it: u32) CompressedTileRef {
        return (@as(CompressedTileRef, salt) << @intCast(self.tile_bits)) | @as(CompressedTileRef, it);
    }

    /// Decode tile salt from ref
    pub fn decodeTileIdSalt(self: *const Self, ref: CompressedTileRef) u32 {
        const salt_mask = (@as(CompressedTileRef, 1) << @intCast(self.salt_bits)) - 1;
        return @intCast((ref >> @intCast(self.tile_bits)) & salt_mask);
    }

    /// Decode tile index from ref
    pub fn decodeTileIdTile(self: *const Self, ref: CompressedTileRef) u32 {
        const tile_mask = (@as(CompressedTileRef, 1) << @intCast(self.tile_bits)) - 1;
        return @intCast(ref & tile_mask);
    }

    /// Encode obstacle ID from salt and index
    pub fn encodeObstacleId(_: *const Self, salt: u16, it: u16) ObstacleRef {
        return (@as(ObstacleRef, salt) << 16) | @as(ObstacleRef, it);
    }

    /// Decode obstacle salt from ref
    pub fn decodeObstacleIdSalt(_: *const Self, ref: ObstacleRef) u16 {
        const salt_mask = (@as(ObstacleRef, 1) << 16) - 1;
        return @intCast((ref >> 16) & salt_mask);
    }

    /// Decode obstacle index from ref
    pub fn decodeObstacleIdObstacle(_: *const Self, ref: ObstacleRef) u16 {
        const obst_mask = (@as(ObstacleRef, 1) << 16) - 1;
        return @intCast(ref & obst_mask);
    }

    /// Get tile reference
    pub fn getTileRef(self: *const Self, tile: *const CompressedTile) CompressedTileRef {
        const offset = @intFromPtr(tile) - @intFromPtr(self.tiles.ptr);
        const it: u32 = @intCast(offset / @sizeOf(CompressedTile));
        return self.encodeTileId(tile.salt, it);
    }

    /// Get tile by reference
    pub fn getTileByRef(self: *const Self, ref: CompressedTileRef) ?*const CompressedTile {
        if (ref == 0) return null;

        const tile_index = self.decodeTileIdTile(ref);
        const tile_salt = self.decodeTileIdSalt(ref);

        if (tile_index >= self.params.max_tiles) return null;

        const tile = &self.tiles[tile_index];
        if (tile.salt != tile_salt) return null;

        return tile;
    }

    /// Get obstacle reference
    pub fn getObstacleRef(self: *const Self, ob: *const TileCacheObstacle) ObstacleRef {
        const offset = @intFromPtr(ob) - @intFromPtr(self.obstacles.ptr);
        const idx: u16 = @intCast(offset / @sizeOf(TileCacheObstacle));
        return self.encodeObstacleId(ob.salt, idx);
    }

    /// Get obstacle by reference
    pub fn getObstacleByRef(self: *const Self, ref: ObstacleRef) ?*const TileCacheObstacle {
        if (ref == 0) return null;

        const idx = self.decodeObstacleIdObstacle(ref);
        const salt = self.decodeObstacleIdSalt(ref);

        if (idx >= self.params.max_obstacles) return null;

        const ob = &self.obstacles[idx];
        if (ob.salt != salt) return null;

        return ob;
    }

    /// Compute tile hash
    fn computeTileHash(x: i32, y: i32, mask: usize) usize {
        const h1: u32 = 0x8da6b343; // Large multiplicative constants
        const h2: u32 = 0xd8163841; // arbitrarily chosen primes
        const n = h1 *% @as(u32, @bitCast(x)) +% h2 *% @as(u32, @bitCast(y));
        return @as(usize, n) & mask;
    }

    /// Get tiles at grid position
    pub fn getTilesAt(self: *const Self, tx: i32, ty: i32, tiles: []CompressedTileRef) usize {
        var n: usize = 0;

        // Find tile based on hash
        const h = computeTileHash(tx, ty, self.tile_lut_mask);
        var tile = self.pos_lookup[h];

        while (tile) |t| {
            if (t.header) |header| {
                if (header.tx == tx and header.ty == ty) {
                    if (n < tiles.len) {
                        tiles[n] = self.getTileRef(t);
                        n += 1;
                    }
                }
            }
            tile = t.next;
        }

        return n;
    }

    /// Get tile at specific grid position and layer
    pub fn getTileAt(self: *Self, tx: i32, ty: i32, tlayer: i32) ?*CompressedTile {
        const h = computeTileHash(tx, ty, self.tile_lut_mask);
        var tile = self.pos_lookup[h];

        while (tile) |t| {
            if (t.header) |header| {
                if (header.tx == tx and header.ty == ty and header.tlayer == tlayer) {
                    return t;
                }
            }
            tile = t.next;
        }

        return null;
    }

    /// Add a tile to the cache
    pub fn addTile(
        self: *Self,
        data: []u8,
        flags: CompressedTileFlags,
    ) !CompressedTileRef {
        // Validate header
        if (data.len < @sizeOf(TileCacheLayerHeader)) {
            return error.InvalidData;
        }

        const header: *TileCacheLayerHeader = @ptrCast(@alignCast(data.ptr));
        if (header.magic != builder_mod.TILECACHE_MAGIC) {
            return error.WrongMagic;
        }
        if (header.version != builder_mod.TILECACHE_VERSION) {
            return error.WrongVersion;
        }

        // Check if location is free
        if (self.getTileAt(header.tx, header.ty, header.tlayer) != null) {
            return error.TileExists;
        }

        // Allocate a tile
        var tile = self.next_free_tile orelse return error.OutOfMemory;
        self.next_free_tile = tile.next;
        tile.next = null;

        // Insert tile into position lookup
        const h = Self.computeTileHash(header.tx, header.ty, self.tile_lut_mask);
        tile.next = self.pos_lookup[h];
        self.pos_lookup[h] = tile;

        // Initialize tile
        const header_size = math.align4(@sizeOf(TileCacheLayerHeader));
        tile.header = header;
        tile.data = data;
        tile.compressed = data[header_size..];
        tile.flags = flags;

        return self.getTileRef(tile);
    }

    /// Remove a tile from the cache
    pub fn removeTile(self: *Self, ref: CompressedTileRef) !?[]u8 {
        if (ref == 0) return error.InvalidParam;

        const tile_index = self.decodeTileIdTile(ref);
        const tile_salt = self.decodeTileIdSalt(ref);

        if (tile_index >= self.params.max_tiles) return error.InvalidParam;

        const tile = &self.tiles[tile_index];
        if (tile.salt != tile_salt) return error.InvalidParam;

        // Remove from hash
        if (tile.header) |header| {
            const h = Self.computeTileHash(header.tx, header.ty, self.tile_lut_mask);

            var prev: ?*CompressedTile = null;
            var cur = self.pos_lookup[h];

            while (cur) |c| {
                if (c == tile) {
                    if (prev) |p| {
                        p.next = c.next;
                    } else {
                        self.pos_lookup[h] = c.next;
                    }
                    break;
                }
                prev = c;
                cur = c.next;
            }
        }

        // Save data pointer if not owned
        var data: ?[]u8 = null;
        if (!tile.flags.free_data) {
            data = tile.data;
        } else if (tile.data.len > 0) {
            self.allocator.free(tile.data);
        }

        // Reset tile
        tile.* = CompressedTile{
            .salt = tile.salt +% 1,
            .header = null,
            .compressed = &[_]u8{},
            .data = &[_]u8{},
            .flags = .{},
            .next = null,
        };

        // Add to freelist
        tile.next = self.next_free_tile;
        self.next_free_tile = tile;

        return data;
    }

    /// Add a cylinder obstacle
    pub fn addObstacle(
        self: *Self,
        pos: *const [3]f32,
        radius: f32,
        height: f32,
    ) !ObstacleRef {
        var ob = self.next_free_obstacle orelse return error.OutOfMemory;
        self.next_free_obstacle = ob.next;
        ob.next = null;

        ob.shape = .{
            .cylinder = .{
                .pos = pos.*,
                .radius = radius,
                .height = height,
            },
        };
        ob.state = .processing;
        ob.ntouched = 0;
        ob.npending = 0;

        const ref = self.getObstacleRef(ob);

        // Add to request queue
        if (self.nreqs < MAX_REQUESTS) {
            self.reqs[self.nreqs] = .{
                .action = .add,
                .ref = ref,
            };
            self.nreqs += 1;
        }

        return ref;
    }

    /// Add an AABB obstacle
    pub fn addBoxObstacle(
        self: *Self,
        bmin: *const [3]f32,
        bmax: *const [3]f32,
    ) !ObstacleRef {
        var ob = self.next_free_obstacle orelse return error.OutOfMemory;
        self.next_free_obstacle = ob.next;
        ob.next = null;

        ob.shape = .{
            .box = .{
                .bmin = bmin.*,
                .bmax = bmax.*,
            },
        };
        ob.state = .processing;
        ob.ntouched = 0;
        ob.npending = 0;

        const ref = self.getObstacleRef(ob);

        // Add to request queue
        if (self.nreqs < MAX_REQUESTS) {
            self.reqs[self.nreqs] = .{
                .action = .add,
                .ref = ref,
            };
            self.nreqs += 1;
        }

        return ref;
    }

    /// Add an oriented box obstacle
    pub fn addOrientedBoxObstacle(
        self: *Self,
        center: *const [3]f32,
        half_extents: *const [3]f32,
        y_radians: f32,
    ) !ObstacleRef {
        var ob = self.next_free_obstacle orelse return error.OutOfMemory;
        self.next_free_obstacle = ob.next;
        ob.next = null;

        // Calculate rotation auxiliary values
        // rot_aux[0] = cos(0.5*angle)*sin(-0.5*angle)
        // rot_aux[1] = cos(0.5*angle)*cos(0.5*angle) - 0.5
        const half_angle = y_radians * 0.5;
        const cos_half = @cos(half_angle);

        ob.shape = .{
            .oriented_box = .{
                .center = center.*,
                .half_extents = half_extents.*,
                .rot_aux = .{
                    cos_half * @sin(-half_angle),
                    cos_half * cos_half - 0.5,
                },
            },
        };
        ob.state = .processing;
        ob.ntouched = 0;
        ob.npending = 0;

        const ref = self.getObstacleRef(ob);

        // Add to request queue
        if (self.nreqs < MAX_REQUESTS) {
            self.reqs[self.nreqs] = .{
                .action = .add,
                .ref = ref,
            };
            self.nreqs += 1;
        }

        return ref;
    }

    /// Remove an obstacle
    pub fn removeObstacle(self: *Self, ref: ObstacleRef) !void {
        if (ref == 0) return error.InvalidParam;

        // Add to request queue
        if (self.nreqs < MAX_REQUESTS) {
            self.reqs[self.nreqs] = .{
                .action = .remove,
                .ref = ref,
            };
            self.nreqs += 1;
        } else {
            return error.QueueFull;
        }
    }

    // ============================================================================
    // Helper Functions
    // ============================================================================

    fn contains(refs: []const CompressedTileRef, ref: CompressedTileRef) bool {
        for (refs) |r| {
            if (r == ref) return true;
        }
        return false;
    }

    pub fn calcTightTileBounds(self: *const Self, header: *const TileCacheLayerHeader, bmin: *[3]f32, bmax: *[3]f32) void {
        const cs = self.params.cs;
        bmin[0] = header.bmin[0] + @as(f32, @floatFromInt(header.minx)) * cs;
        bmin[1] = header.bmin[1];
        bmin[2] = header.bmin[2] + @as(f32, @floatFromInt(header.miny)) * cs;
        bmax[0] = header.bmin[0] + @as(f32, @floatFromInt(header.maxx + 1)) * cs;
        bmax[1] = header.bmax[1];
        bmax[2] = header.bmin[2] + @as(f32, @floatFromInt(header.maxy + 1)) * cs;
    }

    pub fn getObstacleBounds(self: *const Self, ob: *const TileCacheObstacle, bmin: *[3]f32, bmax: *[3]f32) void {
        switch (ob.shape) {
            .cylinder => |cl| {
                bmin[0] = cl.pos[0] - cl.radius;
                bmin[1] = cl.pos[1];
                bmin[2] = cl.pos[2] - cl.radius;
                bmax[0] = cl.pos[0] + cl.radius;
                bmax[1] = cl.pos[1] + cl.height;
                bmax[2] = cl.pos[2] + cl.radius;
            },
            .box => |box| {
                @memcpy(bmin, &box.bmin);
                @memcpy(bmax, &box.bmax);
            },
            .oriented_box => |oriented_box| {
                const maxr = 1.41 * @max(oriented_box.half_extents[0], oriented_box.half_extents[2]);
                bmin[0] = oriented_box.center[0] - maxr;
                bmax[0] = oriented_box.center[0] + maxr;
                bmin[1] = oriented_box.center[1] - oriented_box.half_extents[1];
                bmax[1] = oriented_box.center[1] + oriented_box.half_extents[1];
                bmin[2] = oriented_box.center[2] - maxr;
                bmax[2] = oriented_box.center[2] + maxr;
            },
        }
        _ = self;
    }

    pub fn queryTiles(
        self: *const Self,
        bmin: [3]f32,
        bmax: [3]f32,
        results: []CompressedTileRef,
        result_count: *i32,
        max_results: i32,
    ) Status {
        const MAX_TILES = 32;
        var tiles: [MAX_TILES]CompressedTileRef = undefined;

        var n: i32 = 0;

        const tw = @as(f32, @floatFromInt(self.params.width)) * self.params.cs;
        const th = @as(f32, @floatFromInt(self.params.height)) * self.params.cs;
        const tx0: i32 = @intFromFloat(@floor((bmin[0] - self.params.orig[0]) / tw));
        const tx1: i32 = @intFromFloat(@floor((bmax[0] - self.params.orig[0]) / tw));
        const ty0: i32 = @intFromFloat(@floor((bmin[2] - self.params.orig[2]) / th));
        const ty1: i32 = @intFromFloat(@floor((bmax[2] - self.params.orig[2]) / th));

        var ty = ty0;
        while (ty <= ty1) : (ty += 1) {
            var tx = tx0;
            while (tx <= tx1) : (tx += 1) {
                const ntiles = self.getTilesAt(tx, ty, &tiles);

                var i: usize = 0;
                while (i < ntiles) : (i += 1) {
                    const tile = &self.tiles[self.decodeTileIdTile(tiles[i])];
                    var tbmin: [3]f32 = undefined;
                    var tbmax: [3]f32 = undefined;
                    self.calcTightTileBounds(tile.header.?, &tbmin, &tbmax);

                    if (overlapBounds(&bmin, &bmax, &tbmin, &tbmax)) {
                        if (n < max_results) {
                            results[@intCast(n)] = tiles[@intCast(i)];
                            n += 1;
                        }
                    }
                }
            }
        }

        result_count.* = n;
        return Status{ .success = true };
    }

    fn overlapBounds(amin: *const [3]f32, amax: *const [3]f32, bmin: *const [3]f32, bmax: *const [3]f32) bool {
        var overlap = true;
        overlap = if (amin[0] > bmax[0] or amax[0] < bmin[0]) false else overlap;
        overlap = if (amin[1] > bmax[1] or amax[1] < bmin[1]) false else overlap;
        overlap = if (amin[2] > bmax[2] or amax[2] < bmin[2]) false else overlap;
        return overlap;
    }

    // ============================================================================
    // NavMesh Building
    // ============================================================================

    pub fn update(self: *Self, dt: f32, navmesh: *NavMesh, up_to_date: ?*bool) !Status {
        _ = dt;

        if (self.nupdate == 0) {
            // Process requests
            var i: i32 = 0;
            while (i < self.nreqs) : (i += 1) {
                const req = &self.reqs[@intCast(i)];

                const idx = self.decodeObstacleIdObstacle(req.ref);
                if (@as(i32, @intCast(idx)) >= self.params.max_obstacles) {
                    continue;
                }
                const ob = &self.obstacles[idx];
                const salt = self.decodeObstacleIdSalt(req.ref);
                if (ob.salt != salt) {
                    continue;
                }

                if (req.action == .add) {
                    // Find touched tiles
                    var bmin: [3]f32 = undefined;
                    var bmax: [3]f32 = undefined;
                    self.getObstacleBounds(ob, &bmin, &bmax);

                    var ntouched: i32 = 0;
                    _ = self.queryTiles(bmin, bmax, &ob.touched, &ntouched, MAX_TOUCHED_TILES);
                    ob.ntouched = @intCast(ntouched);

                    // Add tiles to update list
                    ob.npending = 0;
                    var j: usize = 0;
                    while (j < ob.ntouched) : (j += 1) {
                        if (self.nupdate < MAX_UPDATE) {
                            if (!contains(self.update_queue[0..@intCast(self.nupdate)], ob.touched[j])) {
                                self.update_queue[@intCast(self.nupdate)] = ob.touched[j];
                                self.nupdate += 1;
                            }
                            ob.pending[ob.npending] = ob.touched[j];
                            ob.npending += 1;
                        }
                    }
                } else if (req.action == .remove) {
                    // Prepare to remove obstacle
                    ob.state = .removing;
                    // Add tiles to update list
                    ob.npending = 0;
                    var j: usize = 0;
                    while (j < ob.ntouched) : (j += 1) {
                        if (self.nupdate < MAX_UPDATE) {
                            if (!contains(self.update_queue[0..@intCast(self.nupdate)], ob.touched[j])) {
                                self.update_queue[@intCast(self.nupdate)] = ob.touched[j];
                                self.nupdate += 1;
                            }
                            ob.pending[ob.npending] = ob.touched[j];
                            ob.npending += 1;
                        }
                    }
                }
            }

            self.nreqs = 0;
        }

        var status = Status{ .success = true };

        // Process updates
        if (self.nupdate != 0) {
            // Build mesh
            const ref = self.update_queue[0];
            status = try self.buildNavMeshTile(ref, navmesh);
            self.nupdate -= 1;
            if (self.nupdate > 0) {
                // Shift update array left
                var i: usize = 0;
                while (i < self.nupdate) : (i += 1) {
                    self.update_queue[i] = self.update_queue[i + 1];
                }
            }

            // Update obstacle states
            var i: i32 = 0;
            while (i < self.params.max_obstacles) : (i += 1) {
                const ob = &self.obstacles[@intCast(i)];
                if (ob.state == .processing or ob.state == .removing) {
                    // Remove handled tile from pending list
                    var j: usize = 0;
                    while (j < ob.npending) : (j += 1) {
                        if (ob.pending[j] == ref) {
                            ob.pending[j] = ob.pending[ob.npending - 1];
                            ob.npending -= 1;
                            break;
                        }
                    }

                    // If all pending tiles processed, change state
                    if (ob.npending == 0) {
                        if (ob.state == .processing) {
                            ob.state = .processed;
                        } else if (ob.state == .removing) {
                            ob.state = .empty;
                            // Update salt, salt should never be zero
                            ob.salt = (ob.salt + 1) & ((1 << 16) - 1);
                            if (ob.salt == 0) {
                                ob.salt = 1;
                            }
                            // Return obstacle to free list
                            ob.next = self.next_free_obstacle;
                            self.next_free_obstacle = ob;
                        }
                    }
                }
            }
        }

        if (up_to_date) |utd| {
            utd.* = self.nupdate == 0 and self.nreqs == 0;
        }

        return status;
    }

    pub fn buildNavMeshTilesAt(self: *Self, tx: i32, ty: i32, navmesh: *NavMesh) !Status {
        const MAX_TILES = 32;
        var tiles: [MAX_TILES]CompressedTileRef = undefined;
        var ntiles: i32 = 0;
        _ = self.getTilesAt(tx, ty, &tiles, &ntiles, MAX_TILES);

        var i: i32 = 0;
        while (i < ntiles) : (i += 1) {
            const status = try self.buildNavMeshTile(tiles[@intCast(i)], navmesh);
            if (status.isFailure()) {
                return status;
            }
        }

        return Status{ .success = true };
    }

    pub fn buildNavMeshTile(self: *Self, ref: CompressedTileRef, navmesh: *NavMesh) !Status {
        const idx = self.decodeTileIdTile(ref);
        if (idx > @as(u32, @intCast(self.params.max_tiles))) {
            return Status{ .failure = true, .invalid_param = true };
        }
        const tile = &self.tiles[idx];
        const salt = self.decodeTileIdSalt(ref);
        if (tile.salt != salt) {
            return Status{ .failure = true, .invalid_param = true };
        }

        // Note: In the original C++ version, temp allocator is reset here
        // For Zig, we rely on Arena allocator or defer cleanup

        // Decompress tile layer data
        const layer = builder_mod.decompressTileCacheLayer(
            self.allocator,
            self.comp.?,
            tile.compressed,
        ) catch {
            return Status{ .failure = true };
        };
        defer builder_mod.freeTileCacheLayer(self.allocator, layer);

        // Rasterize obstacles
        var i: i32 = 0;
        while (i < self.params.max_obstacles) : (i += 1) {
            const ob = &self.obstacles[@intCast(i)];
            if (ob.state == .empty or ob.state == .removing) {
                continue;
            }
            if (contains(ob.touched[0..ob.ntouched], ref)) {
                switch (ob.shape) {
                    .cylinder => |cyl| {
                        _ = builder_mod.markCylinderArea(
                            layer,
                            &tile.header.?.bmin,
                            self.params.cs,
                            self.params.ch,
                            &cyl.pos,
                            cyl.radius,
                            cyl.height,
                            0,
                        );
                    },
                    .box => |box| {
                        _ = builder_mod.markBoxArea(
                            layer,
                            &tile.header.?.bmin,
                            self.params.cs,
                            self.params.ch,
                            &box.bmin,
                            &box.bmax,
                            0,
                        );
                    },
                    .oriented_box => |obb| {
                        _ = builder_mod.markOrientedBoxArea(
                            layer,
                            &tile.header.?.bmin,
                            self.params.cs,
                            self.params.ch,
                            &obb.center,
                            &obb.half_extents,
                            &obb.rot_aux,
                            0,
                        );
                    },
                }
            }
        }

        // Build navmesh
        const walkable_climb_vx: i32 = @intFromFloat(self.params.walkable_climb / self.params.ch);
        const status_regions = try builder_mod.buildTileCacheRegions(
            self.allocator,
            layer,
            walkable_climb_vx,
        );
        if (status_regions.isFailure()) {
            return status_regions;
        }

        const lcset = try builder_mod.allocTileCacheContourSet(self.allocator);
        defer builder_mod.freeTileCacheContourSet(self.allocator, lcset);

        lcset.* = try builder_mod.buildTileCacheContours(
            self.allocator,
            layer,
            walkable_climb_vx,
            self.params.max_simplification_error,
        );

        const lmesh = try builder_mod.allocTileCachePolyMesh(self.allocator);
        defer builder_mod.freeTileCachePolyMesh(self.allocator, lmesh);

        const status_polymesh = try builder_mod.buildTileCachePolyMesh(
            self.allocator,
            &lcset.*,
            lmesh,
        );
        if (status_polymesh.isFailure()) {
            return status_polymesh;
        }

        // Early out if the mesh tile is empty
        if (lmesh.npolys == 0) {
            // Remove existing tile
            if (navmesh.getTileAt(tile.header.?.tx, tile.header.?.ty, tile.header.?.tlayer)) |existing_tile| {
                const tile_ref = navmesh.getTileRef(existing_tile);
                _ = try navmesh.removeTile(tile_ref);
            }
            return Status{ .success = true };
        }

        // Create NavMesh tile
        var params = std.mem.zeroes(NavMeshCreateParams);
        params.verts = lmesh.verts;
        params.vert_count = lmesh.nverts;
        params.polys = lmesh.polys;
        params.poly_areas = lmesh.areas;
        params.poly_flags = lmesh.flags;
        params.poly_count = lmesh.npolys;
        params.nvp = common.VERTS_PER_POLYGON;
        params.walkable_height = self.params.walkable_height;
        params.walkable_radius = self.params.walkable_radius;
        params.walkable_climb = self.params.walkable_climb;
        params.tile_x = tile.header.?.tx;
        params.tile_y = tile.header.?.ty;
        params.tile_layer = tile.header.?.tlayer;
        params.cs = self.params.cs;
        params.ch = self.params.ch;
        params.build_bv_tree = false;
        @memcpy(&params.bmin, &tile.header.?.bmin);
        @memcpy(&params.bmax, &tile.header.?.bmax);

        // Apply mesh process callback if available
        if (self.tmproc) |proc| {
            proc.process(&params, lmesh.areas, lmesh.flags);
        }

        // Create NavMesh data
        const nav_data = try detour_builder.createNavMeshData(&params, self.allocator);
        errdefer self.allocator.free(nav_data);

        // Remove existing tile
        if (navmesh.getTileAt(tile.header.?.tx, tile.header.?.ty, tile.header.?.tlayer)) |existing_tile| {
            const tile_ref = navmesh.getTileRef(existing_tile);
            _ = try navmesh.removeTile(tile_ref);
        }

        // Add new tile
        const flags = common.TileFlags{}; // Default flags
        _ = try navmesh.addTile(nav_data, flags, 0);

        return Status{ .success = true };
    }
};
