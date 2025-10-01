const std = @import("std");
const math = @import("../math.zig");
const common = @import("common.zig");
const Vec3 = math.Vec3;
const AABB = math.AABB;
const PolyRef = common.PolyRef;
const TileRef = common.TileRef;
const Status = common.Status;

/// Polygon within navigation mesh
pub const Poly = struct {
    /// Index to first link (or NULL_LINK)
    first_link: u32,

    /// Vertex indices
    verts: [common.VERTS_PER_POLYGON]u16,

    /// Neighbor polygon references and flags
    neis: [common.VERTS_PER_POLYGON]u16,

    /// User-defined flags
    flags: u16,

    /// Vertex count
    vert_count: u8,

    /// Area and type (packed)
    area_and_type: u8,

    pub fn init() Poly {
        return .{
            .first_link = common.NULL_LINK,
            .verts = [_]u16{0} ** common.VERTS_PER_POLYGON,
            .neis = [_]u16{0} ** common.VERTS_PER_POLYGON,
            .flags = 0,
            .vert_count = 0,
            .area_and_type = 0,
        };
    }

    pub fn setArea(self: *Poly, area: u8) void {
        self.area_and_type = (self.area_and_type & 0xc0) | (area & 0x3f);
    }

    pub fn setType(self: *Poly, poly_type: common.PolyType) void {
        const t = @intFromEnum(poly_type);
        self.area_and_type = (self.area_and_type & 0x3f) | (t << 6);
    }

    pub fn getArea(self: *const Poly) u8 {
        return self.area_and_type & 0x3f;
    }

    pub fn getType(self: *const Poly) common.PolyType {
        return @enumFromInt(self.area_and_type >> 6);
    }
};

/// Detail polygon
pub const PolyDetail = struct {
    vert_base: u32, // Offset in detailVerts
    tri_base: u32, // Offset in detailTris
    vert_count: u8,
    tri_count: u8,

    pub fn init() PolyDetail {
        return .{
            .vert_base = 0,
            .tri_base = 0,
            .vert_count = 0,
            .tri_count = 0,
        };
    }
};

/// Link between polygons
pub const Link = struct {
    ref: PolyRef, // Neighbor reference
    next: u32, // Index of next link
    edge: u8, // Polygon edge that owns this link
    side: u8, // Boundary link side
    bmin: u8, // Minimum sub-edge area
    bmax: u8, // Maximum sub-edge area

    pub fn init() Link {
        return .{
            .ref = 0,
            .next = common.NULL_LINK,
            .edge = 0,
            .side = 0,
            .bmin = 0,
            .bmax = 0,
        };
    }
};

/// Bounding volume node
pub const BVNode = struct {
    bmin: [3]u16,
    bmax: [3]u16,
    i: i32, // Index (negative for escape sequence)

    pub fn init() BVNode {
        return .{
            .bmin = [_]u16{0} ** 3,
            .bmax = [_]u16{0} ** 3,
            .i = 0,
        };
    }
};

/// Off-mesh connection
pub const OffMeshConnection = struct {
    pos: [6]f32, // Endpoints [(ax,ay,az,bx,by,bz)]
    rad: f32, // Endpoint radius
    poly: u16, // Polygon reference
    flags: u8, // Link flags
    side: u8, // Endpoint side
    user_id: u32, // User-assigned ID

    pub fn init() OffMeshConnection {
        return .{
            .pos = [_]f32{0} ** 6,
            .rad = 0,
            .poly = 0,
            .flags = 0,
            .side = 0,
            .user_id = 0,
        };
    }
};

/// Mesh tile header
pub const MeshHeader = struct {
    magic: i32,
    version: i32,
    x: i32,
    y: i32,
    layer: i32,
    user_id: u32,
    poly_count: i32,
    vert_count: i32,
    max_link_count: i32,
    detail_mesh_count: i32,
    detail_vert_count: i32,
    detail_tri_count: i32,
    bv_node_count: i32,
    off_mesh_con_count: i32,
    off_mesh_base: i32,
    walkable_height: f32,
    walkable_radius: f32,
    walkable_climb: f32,
    bmin: Vec3,
    bmax: Vec3,
    bv_quant_factor: f32,

    pub fn init() MeshHeader {
        return .{
            .magic = common.NAVMESH_MAGIC,
            .version = common.NAVMESH_VERSION,
            .x = 0,
            .y = 0,
            .layer = 0,
            .user_id = 0,
            .poly_count = 0,
            .vert_count = 0,
            .max_link_count = 0,
            .detail_mesh_count = 0,
            .detail_vert_count = 0,
            .detail_tri_count = 0,
            .bv_node_count = 0,
            .off_mesh_con_count = 0,
            .off_mesh_base = 0,
            .walkable_height = 0,
            .walkable_radius = 0,
            .walkable_climb = 0,
            .bmin = Vec3.zero(),
            .bmax = Vec3.zero(),
            .bv_quant_factor = 0,
        };
    }
};

/// Navigation mesh tile
pub const MeshTile = struct {
    salt: u32, // Modification counter
    links_free_list: u32, // Next free link
    header: ?*MeshHeader,
    polys: []Poly,
    verts: []f32,
    links: []Link,
    detail_meshes: []PolyDetail,
    detail_verts: []f32,
    detail_tris: []u8,
    bv_tree: []BVNode,
    off_mesh_cons: []OffMeshConnection,
    data: []u8,
    data_size: usize,
    flags: common.TileFlags,
    next: ?*MeshTile,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MeshTile {
        return .{
            .salt = 0,
            .links_free_list = common.NULL_LINK,
            .header = null,
            .polys = &[_]Poly{},
            .verts = &[_]f32{},
            .links = &[_]Link{},
            .detail_meshes = &[_]PolyDetail{},
            .detail_verts = &[_]f32{},
            .detail_tris = &[_]u8{},
            .bv_tree = &[_]BVNode{},
            .off_mesh_cons = &[_]OffMeshConnection{},
            .data = &[_]u8{},
            .data_size = 0,
            .flags = .{},
            .next = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MeshTile) void {
        if (self.flags.free_data and self.data.len > 0) {
            self.allocator.free(self.data);
        }
        self.* = undefined;
    }
};

/// Navigation mesh parameters
pub const NavMeshParams = struct {
    orig: Vec3, // Origin of tile space
    tile_width: f32,
    tile_height: f32,
    max_tiles: i32,
    max_polys: i32,

    pub fn init() NavMeshParams {
        return .{
            .orig = Vec3.zero(),
            .tile_width = 0,
            .tile_height = 0,
            .max_tiles = 0,
            .max_polys = 0,
        };
    }
};

/// Navigation mesh
pub const NavMesh = struct {
    params: NavMeshParams,
    orig: Vec3,
    tile_width: f32,
    tile_height: f32,
    max_tiles: i32,
    tile_lut_size: i32,
    tile_lut_mask: i32,
    pos_lookup: []?*MeshTile,
    next_free: ?*MeshTile,
    tiles: []MeshTile,
    salt_bits: u32,
    tile_bits: u32,
    poly_bits: u32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, params: NavMeshParams) !Self {
        const tile_bits: u32 = @min(math.ilog2(math.nextPow2(@intCast(params.max_tiles))), 14);
        const poly_bits: u32 = @min(math.ilog2(math.nextPow2(@intCast(params.max_polys))), 20);
        const salt_bits: u32 = @min(32 - tile_bits - poly_bits, 16);

        const tile_lut_size = math.nextPow2(@intCast(@divTrunc(params.max_tiles, 4)));
        const pos_lookup = try allocator.alloc(?*MeshTile, tile_lut_size);
        @memset(pos_lookup, null);

        const tiles = try allocator.alloc(MeshTile, @intCast(params.max_tiles));
        for (tiles) |*tile| {
            tile.* = MeshTile.init(allocator);
        }

        // Build freelist
        for (0..tiles.len - 1) |i| {
            tiles[i].salt = 1;
            tiles[i].next = &tiles[i + 1];
        }
        tiles[tiles.len - 1].salt = 1;
        tiles[tiles.len - 1].next = null;

        return Self{
            .params = params,
            .orig = params.orig,
            .tile_width = params.tile_width,
            .tile_height = params.tile_height,
            .max_tiles = params.max_tiles,
            .tile_lut_size = @intCast(tile_lut_size),
            .tile_lut_mask = @intCast(tile_lut_size - 1),
            .pos_lookup = pos_lookup,
            .next_free = &tiles[0],
            .tiles = tiles,
            .salt_bits = salt_bits,
            .tile_bits = tile_bits,
            .poly_bits = poly_bits,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.tiles) |*tile| {
            tile.deinit();
        }
        self.allocator.free(self.tiles);
        self.allocator.free(self.pos_lookup);
        self.* = undefined;
    }

    pub fn encodePolyId(self: *const Self, salt: u32, it: u32, ip: u32) PolyRef {
        const salt_shift: u5 = @intCast(self.poly_bits + self.tile_bits);
        const tile_shift: u5 = @intCast(self.poly_bits);

        return (salt << salt_shift) | (it << tile_shift) | ip;
    }

    pub fn decodePolyId(self: *const Self, ref: PolyRef) struct { salt: u32, tile: u32, poly: u32 } {
        const salt_shift: u5 = @intCast(self.poly_bits + self.tile_bits);
        const tile_shift: u5 = @intCast(self.poly_bits);
        const salt_bits_u5: u5 = @intCast(self.salt_bits);
        const tile_bits_u5: u5 = @intCast(self.tile_bits);
        const poly_bits_u5: u5 = @intCast(self.poly_bits);

        const salt_mask: u32 = (@as(u32, 1) << salt_bits_u5) - 1;
        const tile_mask: u32 = (@as(u32, 1) << tile_bits_u5) - 1;
        const poly_mask: u32 = (@as(u32, 1) << poly_bits_u5) - 1;

        return .{
            .salt = (ref >> salt_shift) & salt_mask,
            .tile = (ref >> tile_shift) & tile_mask,
            .poly = ref & poly_mask,
        };
    }

    pub fn calcTileLoc(self: *const Self, pos: Vec3) struct { x: i32, y: i32 } {
        return .{
            .x = @intFromFloat(@floor((pos.x - self.orig.x) / self.tile_width)),
            .y = @intFromFloat(@floor((pos.z - self.orig.z) / self.tile_height)),
        };
    }

    /// Compute tile hash from x,y coordinates
    inline fn computeTileHash(x: i32, y: i32, mask: i32) i32 {
        const h1: u32 = 0x8da6b343; // Large multiplicative constants
        const h2: u32 = 0xd8163841;
        const n: u32 = @bitCast(h1 *% @as(u32, @bitCast(x)) +% h2 *% @as(u32, @bitCast(y)));
        return @intCast(n & @as(u32, @bitCast(mask)));
    }

    /// Get opposite tile direction
    inline fn oppositeTile(side: i32) i32 {
        return (side + 4) & 0x7;
    }

    /// Get slab coordinate based on side
    inline fn getSlabCoord(va: *const [3]f32, side: i32) f32 {
        if (side == 0 or side == 4) {
            return va[0];
        } else if (side == 2 or side == 6) {
            return va[2];
        }
        return 0;
    }

    /// Calculate slab end points
    fn calcSlabEndPoints(va: *const [3]f32, vb: *const [3]f32, bmin: *[2]f32, bmax: *[2]f32, side: i32) void {
        if (side == 0 or side == 4) {
            if (va[2] < vb[2]) {
                bmin[0] = va[2];
                bmin[1] = va[1];
                bmax[0] = vb[2];
                bmax[1] = vb[1];
            } else {
                bmin[0] = vb[2];
                bmin[1] = vb[1];
                bmax[0] = va[2];
                bmax[1] = va[1];
            }
        } else if (side == 2 or side == 6) {
            if (va[0] < vb[0]) {
                bmin[0] = va[0];
                bmin[1] = va[1];
                bmax[0] = vb[0];
                bmax[1] = vb[1];
            } else {
                bmin[0] = vb[0];
                bmin[1] = vb[1];
                bmax[0] = va[0];
                bmax[1] = va[1];
            }
        }
    }

    /// Check if two slabs overlap
    inline fn overlapSlabs(amin: *const [2]f32, amax: *const [2]f32, bmin: *const [2]f32, bmax: *const [2]f32, px: f32, py: f32) bool {
        // Check for horizontal overlap
        const minx = @max(amin[0] + px, bmin[0] + px);
        const maxx = @min(amax[0] - px, bmax[0] - px);
        if (minx > maxx) return false;

        // Check vertical overlap
        const ad = (amax[1] - amin[1]) / (amax[0] - amin[0]);
        const ak = amin[1] - ad * amin[0];
        const bd = (bmax[1] - bmin[1]) / (bmax[0] - bmin[0]);
        const bk = bmin[1] - bd * bmin[0];
        const aminy = ad * minx + ak;
        const amaxy = ad * maxx + ak;
        const bminy = bd * minx + bk;
        const bmaxy = bd * maxx + bk;
        const dmin = bminy - aminy;
        const dmax = bmaxy - amaxy;

        // Crossing segments always overlap
        if (dmin * dmax < 0) return true;

        // Check for overlap at endpoints
        const thr = py * py * 4.0;
        if (dmin * dmin <= thr or dmax * dmax <= thr) return true;

        return false;
    }

    /// Get base polygon reference for a tile
    pub fn getPolyRefBase(self: *const Self, tile: *const MeshTile) PolyRef {
        if (tile.header == null) return 0;
        const it: u32 = @intCast(self.getTileIndex(tile));
        return self.encodePolyId(tile.salt, it, 0);
    }

    /// Get tile index in the tiles array
    fn getTileIndex(self: *const Self, tile: *const MeshTile) usize {
        const base_ptr = @intFromPtr(self.tiles.ptr);
        const tile_ptr = @intFromPtr(tile);
        return @divExact(tile_ptr - base_ptr, @sizeOf(MeshTile));
    }

    /// Get tile reference
    pub fn getTileRef(self: *const Self, tile: *const MeshTile) TileRef {
        if (tile.header == null) return 0;
        const it: u32 = @intCast(self.getTileIndex(tile));
        return self.encodePolyId(tile.salt, it, 0);
    }

    /// Allocate a link from tile's free list
    fn allocLink(_: *Self, tile: *MeshTile) u32 {
        if (tile.links_free_list == common.NULL_LINK) {
            return common.NULL_LINK;
        }
        const link_idx = tile.links_free_list;
        tile.links_free_list = tile.links[link_idx].next;
        return link_idx;
    }

    /// Free a link and return it to tile's free list
    fn freeLink(self: *Self, tile: *MeshTile, link_idx: u32) void {
        _ = self;
        tile.links[link_idx].next = tile.links_free_list;
        tile.links_free_list = link_idx;
    }

    /// Connect internal links (within tile)
    fn connectIntLinks(self: *Self, tile: *MeshTile) void {
        if (tile.header == null) return;

        const base = self.getPolyRefBase(tile);

        for (0..@intCast(tile.header.?.poly_count)) |i| {
            var poly = &tile.polys[i];
            poly.first_link = common.NULL_LINK;

            if (poly.getType() == .offmesh_connection) continue;

            // Build edge links backwards for proper ordering
            var j: usize = @intCast(poly.vert_count);
            while (j > 0) {
                j -= 1;
                // Skip hard and non-internal edges
                if (poly.neis[j] == 0 or (poly.neis[j] & common.EXT_LINK) != 0) continue;

                const idx = self.allocLink(tile);
                if (idx != common.NULL_LINK) {
                    var link = &tile.links[idx];
                    link.ref = base | @as(PolyRef, poly.neis[j] - 1);
                    link.edge = @intCast(j);
                    link.side = 0xff;
                    link.bmin = 0;
                    link.bmax = 0;
                    // Add to linked list
                    link.next = poly.first_link;
                    poly.first_link = idx;
                }
            }
        }
    }

    /// Get tile at specific coordinates and layer
    pub fn getTileAt(self: *const Self, x: i32, y: i32, layer: i32) ?*MeshTile {
        const h = computeTileHash(x, y, self.tile_lut_mask);
        var tile = self.pos_lookup[@intCast(h)];
        while (tile) |t| {
            if (t.header) |header| {
                if (header.x == x and header.y == y and header.layer == layer) {
                    return t;
                }
            }
            tile = t.next;
        }
        return null;
    }

    /// Get all tiles at specific coordinates (across layers)
    pub fn getTilesAt(self: *const Self, x: i32, y: i32, tiles: []*MeshTile, max_tiles: usize) usize {
        var n: usize = 0;
        const h = computeTileHash(x, y, self.tile_lut_mask);
        var tile = self.pos_lookup[@intCast(h)];
        while (tile) |t| : (tile = t.next) {
            if (t.header) |header| {
                if (header.x == x and header.y == y) {
                    if (n < max_tiles) {
                        tiles[n] = t;
                        n += 1;
                    }
                }
            }
        }
        return n;
    }

    /// Get neighbour tiles at specific side
    pub fn getNeighbourTilesAt(self: *const Self, x: i32, y: i32, side: i32, tiles: []*MeshTile, max_tiles: usize) usize {
        var nx = x;
        var ny = y;
        switch (side) {
            0 => nx += 1,
            1 => {
                nx += 1;
                ny += 1;
            },
            2 => ny += 1,
            3 => {
                nx -= 1;
                ny += 1;
            },
            4 => nx -= 1,
            5 => {
                nx -= 1;
                ny -= 1;
            },
            6 => ny -= 1,
            7 => {
                nx += 1;
                ny -= 1;
            },
            else => {},
        }
        return self.getTilesAt(nx, ny, tiles, max_tiles);
    }

    /// Find polygons connecting to given edge
    fn findConnectingPolys(
        self: *const Self,
        va: *const [3]f32,
        vb: *const [3]f32,
        tile: *const MeshTile,
        side: i32,
        con: []PolyRef,
        conarea: []f32,
        max_con: usize,
    ) usize {
        if (tile.header == null) return 0;

        var amin: [2]f32 = undefined;
        var amax: [2]f32 = undefined;
        calcSlabEndPoints(va, vb, &amin, &amax, side);
        const apos = getSlabCoord(va, side);

        var bmin: [2]f32 = undefined;
        var bmax: [2]f32 = undefined;
        const m = common.EXT_LINK | @as(u16, @intCast(side));
        var n: usize = 0;

        const base = self.getPolyRefBase(tile);

        for (0..@intCast(tile.header.?.poly_count)) |i| {
            const poly = &tile.polys[i];
            const nv: usize = @intCast(poly.vert_count);

            for (0..nv) |j| {
                // Skip edges which do not point to the right side
                if (poly.neis[j] != m) continue;

                const vc_idx = poly.verts[j] * 3;
                const vc: *const [3]f32 = @ptrCast(tile.verts[vc_idx .. vc_idx + 3]);
                const vd_idx = poly.verts[(j + 1) % nv] * 3;
                const vd: *const [3]f32 = @ptrCast(tile.verts[vd_idx .. vd_idx + 3]);
                const bpos = getSlabCoord(vc, side);

                // Segments are not close enough
                if (@abs(apos - bpos) > 0.01) continue;

                // Check if the segments touch
                calcSlabEndPoints(vc, vd, &bmin, &bmax, side);

                if (!overlapSlabs(&amin, &amax, &bmin, &bmax, 0.01, tile.header.?.walkable_climb)) continue;

                // Add return value
                if (n < max_con) {
                    conarea[n * 2 + 0] = @max(amin[0], bmin[0]);
                    conarea[n * 2 + 1] = @min(amax[0], bmax[0]);
                    con[n] = base | @as(PolyRef, @intCast(i));
                    n += 1;
                }
                break;
            }
        }
        return n;
    }

    /// Get tile and polygon by reference
    /// Get tile and poly by ref without error checking (unsafe, for performance)
    pub fn getTileAndPolyByRefUnsafe(
        self: *const Self,
        ref: PolyRef,
        tile: *?*const MeshTile,
        poly: *?*const Poly,
    ) void {
        const decoded = self.decodePolyId(ref);
        tile.* = &self.tiles[decoded.tile];
        poly.* = &self.tiles[decoded.tile].polys[decoded.poly];
    }

    pub fn getTileAndPolyByRef(
        self: *const Self,
        ref: PolyRef,
    ) error{InvalidParam}!struct { tile: *MeshTile, poly: *Poly } {
        if (ref == 0) return error.InvalidParam;

        const decoded = self.decodePolyId(ref);
        if (decoded.tile >= @as(u32, @intCast(self.max_tiles))) return error.InvalidParam;
        if (self.tiles[decoded.tile].salt != decoded.salt) return error.InvalidParam;
        if (self.tiles[decoded.tile].header == null) return error.InvalidParam;
        if (decoded.poly >= @as(u32, @intCast(self.tiles[decoded.tile].header.?.poly_count))) {
            return error.InvalidParam;
        }

        const tile = &self.tiles[decoded.tile];
        const poly = &tile.polys[decoded.poly];
        return .{ .tile = tile, .poly = poly };
    }

    /// Set polygon flags
    pub fn setPolyFlags(self: *Self, ref: PolyRef, flags: u16) !void {
        const result = try self.getTileAndPolyByRef(ref);
        result.poly.flags = flags;
    }

    /// Get polygon flags
    pub fn getPolyFlags(self: *const Self, ref: PolyRef) !u16 {
        const result = try self.getTileAndPolyByRef(ref);
        return result.poly.flags;
    }

    /// Set polygon area
    pub fn setPolyArea(self: *Self, ref: PolyRef, area: u8) !void {
        const result = try self.getTileAndPolyByRef(ref);
        result.poly.setArea(area);
    }

    /// Get polygon area
    pub fn getPolyArea(self: *const Self, ref: PolyRef) !u8 {
        const result = try self.getTileAndPolyByRef(ref);
        return result.poly.getArea();
    }

    /// Query polygons in tile within bounding box (simplified version without BVTree)
    fn queryPolygonsInTile(
        self: *const Self,
        tile: *const MeshTile,
        qmin: *const [3]f32,
        qmax: *const [3]f32,
        polys: []PolyRef,
        max_polys: usize,
    ) usize {
        if (tile.header == null) return 0;

        var n: usize = 0;
        const base = self.getPolyRefBase(tile);

        for (0..@intCast(tile.header.?.poly_count)) |i| {
            const p = &tile.polys[i];
            // Do not return off-mesh connection polygons
            if (p.getType() == .offmesh_connection) continue;

            // Calc polygon bounds
            const v0_idx = p.verts[0] * 3;
            var bmin = [3]f32{
                tile.verts[v0_idx + 0],
                tile.verts[v0_idx + 1],
                tile.verts[v0_idx + 2],
            };
            var bmax = bmin;

            for (1..@intCast(p.vert_count)) |j| {
                const v_idx = p.verts[j] * 3;
                const v = [3]f32{
                    tile.verts[v_idx + 0],
                    tile.verts[v_idx + 1],
                    tile.verts[v_idx + 2],
                };
                bmin[0] = @min(bmin[0], v[0]);
                bmin[1] = @min(bmin[1], v[1]);
                bmin[2] = @min(bmin[2], v[2]);
                bmax[0] = @max(bmax[0], v[0]);
                bmax[1] = @max(bmax[1], v[1]);
                bmax[2] = @max(bmax[2], v[2]);
            }

            // Check overlap
            if (qmin[0] <= bmax[0] and qmax[0] >= bmin[0] and
                qmin[1] <= bmax[1] and qmax[1] >= bmin[1] and
                qmin[2] <= bmax[2] and qmax[2] >= bmin[2])
            {
                if (n < max_polys) {
                    polys[n] = base | @as(PolyRef, @intCast(i));
                    n += 1;
                }
            }
        }
        return n;
    }

    /// Find nearest polygon in tile (simplified version)
    fn findNearestPolyInTile(
        self: *const Self,
        tile: *const MeshTile,
        center: *const [3]f32,
        half_extents: *const [3]f32,
        nearest_pt: *[3]f32,
    ) PolyRef {
        var bmin = [3]f32{
            center[0] - half_extents[0],
            center[1] - half_extents[1],
            center[2] - half_extents[2],
        };
        var bmax = [3]f32{
            center[0] + half_extents[0],
            center[1] + half_extents[1],
            center[2] + half_extents[2],
        };

        var polys: [128]PolyRef = undefined;
        const poly_count = self.queryPolygonsInTile(tile, &bmin, &bmax, &polys, 128);

        var nearest: PolyRef = 0;
        var nearest_dist_sqr: f32 = std.math.floatMax(f32);

        for (0..poly_count) |i| {
            const ref = polys[i];
            const decoded = self.decodePolyId(ref);
            const poly = &tile.polys[decoded.poly];

            // Simplified: use polygon center as closest point
            var poly_center = [3]f32{ 0, 0, 0 };
            for (0..@intCast(poly.vert_count)) |j| {
                const v_idx = poly.verts[j] * 3;
                poly_center[0] += tile.verts[v_idx + 0];
                poly_center[1] += tile.verts[v_idx + 1];
                poly_center[2] += tile.verts[v_idx + 2];
            }
            const nv: f32 = @floatFromInt(poly.vert_count);
            poly_center[0] /= nv;
            poly_center[1] /= nv;
            poly_center[2] /= nv;

            const dx = center[0] - poly_center[0];
            const dy = center[1] - poly_center[1];
            const dz = center[2] - poly_center[2];
            const dist_sqr = dx * dx + dy * dy + dz * dz;

            if (dist_sqr < nearest_dist_sqr) {
                nearest_pt.* = poly_center;
                nearest_dist_sqr = dist_sqr;
                nearest = ref;
            }
        }

        return nearest;
    }

    /// Connect external links between tiles
    fn connectExtLinks(self: *Self, tile: *MeshTile, target: ?*MeshTile, side: i32) void {
        if (tile.header == null) return;

        for (0..@intCast(tile.header.?.poly_count)) |i| {
            var poly = &tile.polys[i];

            const nv: usize = @intCast(poly.vert_count);
            for (0..nv) |j| {
                // Skip non-portal edges
                if ((poly.neis[j] & common.EXT_LINK) == 0) continue;

                const dir = @as(i32, @intCast(poly.neis[j] & 0xff));
                if (side != -1 and dir != side) continue;

                // Create new links
                const va_idx = poly.verts[j] * 3;
                const va: *const [3]f32 = @ptrCast(tile.verts[va_idx .. va_idx + 3]);
                const vb_idx = poly.verts[(j + 1) % nv] * 3;
                const vb: *const [3]f32 = @ptrCast(tile.verts[vb_idx .. vb_idx + 3]);

                var nei: [4]PolyRef = undefined;
                var neia: [4 * 2]f32 = undefined;

                const nnei = if (target) |t|
                    self.findConnectingPolys(va, vb, t, oppositeTile(dir), &nei, &neia, 4)
                else
                    0;

                for (0..nnei) |k| {
                    const idx = self.allocLink(tile);
                    if (idx != common.NULL_LINK) {
                        var link = &tile.links[idx];
                        link.ref = nei[k];
                        link.edge = @intCast(j);
                        link.side = @intCast(dir);

                        link.next = poly.first_link;
                        poly.first_link = idx;

                        // Compress portal limits to a byte value
                        if (dir == 0 or dir == 4) {
                            const tmin = (neia[k * 2 + 0] - va[2]) / (vb[2] - va[2]);
                            const tmax = (neia[k * 2 + 1] - va[2]) / (vb[2] - va[2]);
                            const tmin_clamped = std.math.clamp(if (tmin > tmax) tmax else tmin, 0.0, 1.0);
                            const tmax_clamped = std.math.clamp(if (tmin > tmax) tmin else tmax, 0.0, 1.0);
                            link.bmin = @intFromFloat(@round(tmin_clamped * 255.0));
                            link.bmax = @intFromFloat(@round(tmax_clamped * 255.0));
                        } else if (dir == 2 or dir == 6) {
                            const tmin = (neia[k * 2 + 0] - va[0]) / (vb[0] - va[0]);
                            const tmax = (neia[k * 2 + 1] - va[0]) / (vb[0] - va[0]);
                            const tmin_clamped = std.math.clamp(if (tmin > tmax) tmax else tmin, 0.0, 1.0);
                            const tmax_clamped = std.math.clamp(if (tmin > tmax) tmin else tmax, 0.0, 1.0);
                            link.bmin = @intFromFloat(@round(tmin_clamped * 255.0));
                            link.bmax = @intFromFloat(@round(tmax_clamped * 255.0));
                        }
                    }
                }
            }
        }
    }

    /// Add a tile to the navigation mesh
    pub fn addTile(
        self: *Self,
        data: []u8,
        flags: common.TileFlags,
        last_ref: TileRef,
    ) !TileRef {
        // Verify data format
        const header: *MeshHeader = @ptrCast(@alignCast(data.ptr));
        if (header.magic != common.NAVMESH_MAGIC) return error.WrongMagic;
        if (header.version != common.NAVMESH_VERSION) return error.WrongVersion;

        // Check if location is free
        if (self.getTileAt(header.x, header.y, header.layer)) |_| {
            return error.AlreadyOccupied;
        }

        // Allocate a tile
        var tile: ?*MeshTile = null;
        if (last_ref == 0) {
            // Use next free tile
            if (self.next_free) |free_tile| {
                tile = free_tile;
                self.next_free = free_tile.next;
                free_tile.next = null;
            }
        } else {
            // Try to relocate to specific index
            const decoded = self.decodePolyId(last_ref);
            if (decoded.tile >= @as(u32, @intCast(self.max_tiles))) {
                return error.OutOfMemory;
            }

            var target = &self.tiles[decoded.tile];
            var prev: ?*MeshTile = null;
            var current = self.next_free;

            while (current) |curr| {
                if (curr == target) break;
                prev = curr;
                current = curr.next;
            }

            if (current != target) return error.OutOfMemory;

            // Remove from freelist
            if (prev) |p| {
                p.next = target.next;
            } else {
                self.next_free = target.next;
            }

            // Restore salt
            target.salt = decoded.salt;
            tile = target;
        }

        if (tile == null) return error.OutOfMemory;

        // Insert tile into position lookup
        const h = computeTileHash(header.x, header.y, self.tile_lut_mask);
        tile.?.next = self.pos_lookup[@intCast(h)];
        self.pos_lookup[@intCast(h)] = tile;

        // Patch header pointers
        const header_size = std.mem.alignForward(usize, @sizeOf(MeshHeader), 4);
        const verts_size = std.mem.alignForward(usize, @sizeOf(f32) * 3 * @as(usize, @intCast(header.vert_count)), 4);
        const polys_size = std.mem.alignForward(usize, @sizeOf(Poly) * @as(usize, @intCast(header.poly_count)), 4);
        const links_size = std.mem.alignForward(usize, @sizeOf(Link) * @as(usize, @intCast(header.max_link_count)), 4);
        const detail_meshes_size = std.mem.alignForward(usize, @sizeOf(PolyDetail) * @as(usize, @intCast(header.detail_mesh_count)), 4);
        const detail_verts_size = std.mem.alignForward(usize, @sizeOf(f32) * 3 * @as(usize, @intCast(header.detail_vert_count)), 4);
        const detail_tris_size = std.mem.alignForward(usize, @sizeOf(u8) * 4 * @as(usize, @intCast(header.detail_tri_count)), 4);
        const bvtree_size = std.mem.alignForward(usize, @sizeOf(BVNode) * @as(usize, @intCast(header.bv_node_count)), 4);
        const offmesh_size = std.mem.alignForward(usize, @sizeOf(OffMeshConnection) * @as(usize, @intCast(header.off_mesh_con_count)), 4);

        var offset: usize = header_size;

        // Setup pointers to data sections
        const verts_ptr: [*]f32 = @ptrCast(@alignCast(data[offset..].ptr));
        tile.?.verts = verts_ptr[0..@as(usize, @intCast(header.vert_count)) * 3];
        offset += verts_size;

        const polys_ptr: [*]Poly = @ptrCast(@alignCast(data[offset..].ptr));
        tile.?.polys = polys_ptr[0..@intCast(header.poly_count)];
        offset += polys_size;

        const links_ptr: [*]Link = @ptrCast(@alignCast(data[offset..].ptr));
        tile.?.links = links_ptr[0..@intCast(header.max_link_count)];
        offset += links_size;

        const dmeshes_ptr: [*]PolyDetail = @ptrCast(@alignCast(data[offset..].ptr));
        tile.?.detail_meshes = dmeshes_ptr[0..@intCast(header.detail_mesh_count)];
        offset += detail_meshes_size;

        const dverts_ptr: [*]f32 = @ptrCast(@alignCast(data[offset..].ptr));
        tile.?.detail_verts = dverts_ptr[0..@as(usize, @intCast(header.detail_vert_count)) * 3];
        offset += detail_verts_size;

        const dtris_ptr: [*]u8 = @ptrCast(@alignCast(data[offset..].ptr));
        tile.?.detail_tris = dtris_ptr[0..@as(usize, @intCast(header.detail_tri_count)) * 4];
        offset += detail_tris_size;

        if (bvtree_size > 0) {
            const bvtree_ptr: [*]BVNode = @ptrCast(@alignCast(data[offset..].ptr));
            tile.?.bv_tree = bvtree_ptr[0..@intCast(header.bv_node_count)];
        } else {
            tile.?.bv_tree = &[_]BVNode{};
        }
        offset += bvtree_size;

        if (offmesh_size > 0) {
            const offmesh_ptr: [*]OffMeshConnection = @ptrCast(@alignCast(data[offset..].ptr));
            tile.?.off_mesh_cons = offmesh_ptr[0..@intCast(header.off_mesh_con_count)];
        } else {
            tile.?.off_mesh_cons = &[_]OffMeshConnection{};
        }

        // Build links freelist
        tile.?.links_free_list = 0;
        tile.?.links[@intCast(header.max_link_count - 1)].next = common.NULL_LINK;
        for (0..@intCast(header.max_link_count - 1)) |i| {
            tile.?.links[i].next = @intCast(i + 1);
        }

        // Initialize tile
        tile.?.header = header;
        tile.?.data = data;
        tile.?.data_size = data.len;
        tile.?.flags = flags;

        // Connect internal links
        self.connectIntLinks(tile.?);

        // Create connections with neighbor tiles
        const MAX_NEIS = 32;
        var neis: [MAX_NEIS]*MeshTile = undefined;

        // Connect with layers in current tile
        var nneis = self.getTilesAt(header.x, header.y, &neis, MAX_NEIS);
        for (0..nneis) |jj| {
            if (neis[jj] == tile.?) continue;

            self.connectExtLinks(tile.?, neis[jj], -1);
            self.connectExtLinks(neis[jj], tile.?, -1);
            self.connectExtOffMeshLinks(tile.?, neis[jj], -1);
            self.connectExtOffMeshLinks(neis[jj], tile.?, -1);
        }

        // Connect with neighbor tiles
        for (0..8) |ii| {
            nneis = self.getNeighbourTilesAt(header.x, header.y, @intCast(ii), &neis, MAX_NEIS);
            for (0..nneis) |jj| {
                self.connectExtLinks(tile.?, neis[jj], @intCast(ii));
                self.connectExtLinks(neis[jj], tile.?, oppositeTile(@intCast(ii)));
                self.connectExtOffMeshLinks(tile.?, neis[jj], @intCast(ii));
                self.connectExtOffMeshLinks(neis[jj], tile.?, oppositeTile(@intCast(ii)));
            }
        }

        // Base off-mesh connections to their starting polygons
        self.baseOffMeshLinks(tile.?);
        self.connectExtOffMeshLinks(tile.?, tile.?, -1);

        return self.getTileRef(tile.?);
    }

    /// Base off-mesh connection links
    fn baseOffMeshLinks(self: *Self, tile: *MeshTile) void {
        if (tile.header == null) return;

        const base = self.getPolyRefBase(tile);

        for (0..@intCast(tile.header.?.off_mesh_con_count)) |i| {
            const con = &tile.off_mesh_cons[i];
            var poly = &tile.polys[@intCast(con.poly)];

            const half_extents = [3]f32{ con.rad, tile.header.?.walkable_climb, con.rad };

            // Find polygon to connect to (first vertex - start point)
            const p: *const [3]f32 = @ptrCast(con.pos[0..3]);
            var nearest_pt: [3]f32 = undefined;
            const ref = self.findNearestPolyInTile(tile, p, &half_extents, &nearest_pt);
            if (ref == 0) continue;

            // Check distance
            const dx = nearest_pt[0] - p[0];
            const dz = nearest_pt[2] - p[2];
            if (dx * dx + dz * dz > con.rad * con.rad) continue;

            // Make sure the location is on current mesh
            const v_idx = poly.verts[0] * 3;
            tile.verts[v_idx + 0] = nearest_pt[0];
            tile.verts[v_idx + 1] = nearest_pt[1];
            tile.verts[v_idx + 2] = nearest_pt[2];

            // Link off-mesh connection to target poly
            const idx = self.allocLink(tile);
            if (idx != common.NULL_LINK) {
                var link = &tile.links[idx];
                link.ref = ref;
                link.edge = 0;
                link.side = 0xff;
                link.bmin = 0;
                link.bmax = 0;
                link.next = poly.first_link;
                poly.first_link = idx;
            }

            // Start end-point always connects back to off-mesh connection
            const tidx = self.allocLink(tile);
            if (tidx != common.NULL_LINK) {
                const decoded = self.decodePolyId(ref);
                const land_poly_idx = decoded.poly;
                var land_poly = &tile.polys[land_poly_idx];
                var link = &tile.links[tidx];
                link.ref = base | @as(PolyRef, @intCast(con.poly));
                link.edge = 0xff;
                link.side = 0xff;
                link.bmin = 0;
                link.bmax = 0;
                link.next = land_poly.first_link;
                land_poly.first_link = tidx;
            }
        }
    }

    /// Connect external off-mesh links
    fn connectExtOffMeshLinks(self: *Self, tile: *MeshTile, target: *MeshTile, side: i32) void {
        if (tile.header == null or target.header == null) return;

        const opposite_side: u8 = if (side == -1) 0xff else @intCast(oppositeTile(side));

        for (0..@intCast(target.header.?.off_mesh_con_count)) |i| {
            const target_con = &target.off_mesh_cons[i];
            if (target_con.side != opposite_side) continue;

            var target_poly = &target.polys[@intCast(target_con.poly)];
            // Skip off-mesh connections which start location could not be connected at all
            if (target_poly.first_link == common.NULL_LINK) continue;

            const half_extents = [3]f32{ target_con.rad, target.header.?.walkable_climb, target_con.rad };

            // Find polygon to connect to (second vertex - end point)
            const p: *const [3]f32 = @ptrCast(target_con.pos[3..6]);
            var nearest_pt: [3]f32 = undefined;
            const ref = self.findNearestPolyInTile(tile, p, &half_extents, &nearest_pt);
            if (ref == 0) continue;

            // Check distance
            const dx = nearest_pt[0] - p[0];
            const dz = nearest_pt[2] - p[2];
            if (dx * dx + dz * dz > target_con.rad * target_con.rad) continue;

            // Make sure the location is on current mesh
            const v_idx = target_poly.verts[1] * 3;
            target.verts[v_idx + 0] = nearest_pt[0];
            target.verts[v_idx + 1] = nearest_pt[1];
            target.verts[v_idx + 2] = nearest_pt[2];

            // Link off-mesh connection to target poly
            const idx = self.allocLink(target);
            if (idx != common.NULL_LINK) {
                var link = &target.links[idx];
                link.ref = ref;
                link.edge = 1;
                link.side = opposite_side;
                link.bmin = 0;
                link.bmax = 0;
                link.next = target_poly.first_link;
                target_poly.first_link = idx;
            }

            // Link target poly to off-mesh connection (bidirectional)
            if ((target_con.flags & 1) != 0) { // DT_OFFMESH_CON_BIDIR
                const tidx = self.allocLink(tile);
                if (tidx != common.NULL_LINK) {
                    const decoded = self.decodePolyId(ref);
                    const land_poly_idx = decoded.poly;
                    var land_poly = &tile.polys[land_poly_idx];
                    var link = &tile.links[tidx];
                    link.ref = self.getPolyRefBase(target) | @as(PolyRef, @intCast(target_con.poly));
                    link.edge = 0xff;
                    link.side = if (side == -1) 0xff else @intCast(side);
                    link.bmin = 0;
                    link.bmax = 0;
                    link.next = land_poly.first_link;
                    land_poly.first_link = tidx;
                }
            }
        }
    }

    /// Remove a tile from the navigation mesh
    pub fn removeTile(self: *Self, ref: TileRef) !struct { data: []u8, data_size: usize } {
        if (ref == 0) return error.InvalidParam;

        const decoded = self.decodePolyId(ref);
        if (decoded.tile >= @as(u32, @intCast(self.max_tiles))) return error.InvalidParam;

        var tile = &self.tiles[decoded.tile];
        if (tile.salt != decoded.salt) return error.InvalidParam;
        if (tile.header == null) return error.InvalidParam;

        // Remove tile from hash lookup
        const h = computeTileHash(tile.header.?.x, tile.header.?.y, self.tile_lut_mask);
        var prev: ?*MeshTile = null;
        var current = self.pos_lookup[@intCast(h)];

        while (current) |curr| {
            if (curr == tile) {
                if (prev) |p| {
                    p.next = curr.next;
                } else {
                    self.pos_lookup[@intCast(h)] = curr.next;
                }
                break;
            }
            prev = curr;
            current = curr.next;
        }

        // Save data before clearing
        const data = tile.data;
        const data_size = tile.data_size;

        // Reset tile
        tile.header = null;
        tile.polys = &[_]Poly{};
        tile.verts = &[_]f32{};
        tile.links = &[_]Link{};
        tile.detail_meshes = &[_]PolyDetail{};
        tile.detail_verts = &[_]f32{};
        tile.detail_tris = &[_]u8{};
        tile.bv_tree = &[_]BVNode{};
        tile.off_mesh_cons = &[_]OffMeshConnection{};
        tile.data = &[_]u8{};
        tile.data_size = 0;
        tile.flags = .{};

        // Update salt
        tile.salt = (tile.salt + 1) & ((1 << @intCast(self.salt_bits)) - 1);
        if (tile.salt == 0) tile.salt = 1;

        // Return to freelist
        tile.next = self.next_free;
        self.next_free = tile;

        return .{ .data = data, .data_size = data_size };
    }

    /// Get height on polygon (simplified version without detail mesh)
    /// Returns error if point is not over the polygon
    pub fn getPolyHeight(
        self: *const Self,
        ref: PolyRef,
        pos: *const [3]f32,
        height: *f32,
    ) !void {
        const decoded = self.decodePolyId(ref);
        if (decoded.tile >= @as(u32, @intCast(self.max_tiles))) return error.InvalidParam;

        const tile = &self.tiles[decoded.tile];
        if (tile.salt != decoded.salt or tile.header == null) return error.InvalidParam;
        if (decoded.poly >= @as(u32, @intCast(tile.header.?.poly_count))) return error.InvalidParam;

        const poly = &tile.polys[decoded.poly];

        // Off-mesh connections don't have detail polys
        if (poly.getType() == .offmesh_connection) return error.InvalidParam;

        // Collect vertices
        var verts: [common.VERTS_PER_POLYGON]Vec3 = undefined;
        for (0..poly.vert_count) |i| {
            const v_idx = poly.verts[i] * 3;
            verts[i] = Vec3.init(
                tile.verts[v_idx + 0],
                tile.verts[v_idx + 1],
                tile.verts[v_idx + 2],
            );
        }

        // Check if point is inside polygon
        const p = Vec3.init(pos[0], pos[1], pos[2]);
        if (!math.pointInPolygon(p, verts[0..poly.vert_count])) {
            return error.PointNotInPolygon;
        }

        // Simplified: return average height of vertices
        // TODO: Use detail mesh for accurate height
        var avg_height: f32 = 0;
        for (0..poly.vert_count) |i| {
            avg_height += verts[i].y;
        }
        height.* = avg_height / @as(f32, @floatFromInt(poly.vert_count));
    }

    /// Get closest point on polygon
    pub fn closestPointOnPoly(
        self: *const Self,
        ref: PolyRef,
        pos: *const [3]f32,
        closest: *[3]f32,
        pos_over_poly: ?*bool,
    ) !void {
        const decoded = self.decodePolyId(ref);
        if (decoded.tile >= @as(u32, @intCast(self.max_tiles))) return error.InvalidParam;

        const tile = &self.tiles[decoded.tile];
        if (tile.salt != decoded.salt or tile.header == null) return error.InvalidParam;
        if (decoded.poly >= @as(u32, @intCast(tile.header.?.poly_count))) return error.InvalidParam;

        const poly = &tile.polys[decoded.poly];

        // Start with the input position
        math.vcopy(closest, pos);

        // Try to get height at this position
        var h: f32 = undefined;
        if (self.getPolyHeight(ref, pos, &h)) {
            closest[1] = h;
            if (pos_over_poly) |pop| pop.* = true;
            return;
        } else |_| {
            if (pos_over_poly) |pop| pop.* = false;
        }

        // Point is not over polygon
        // Handle off-mesh connections specially
        if (poly.getType() == .offmesh_connection) {
            const v0 = tile.verts[poly.verts[0] * 3 .. poly.verts[0] * 3 + 3];
            const v1 = tile.verts[poly.verts[1] * 3 .. poly.verts[1] * 3 + 3];
            var t: f32 = undefined;
            _ = math.distancePtSegSqr2D(pos, v0[0..3], v1[0..3], &t);
            math.vlerp(closest, v0[0..3], v1[0..3], t);
            return;
        }

        // Outside poly - use boundary
        try self.closestPointOnPolyBoundary(ref, pos, closest);
    }

    /// Get closest point on polygon boundary (2D, no height detail)
    pub fn closestPointOnPolyBoundary(
        self: *const Self,
        ref: PolyRef,
        pos: *const [3]f32,
        closest: *[3]f32,
    ) !void {
        const decoded = self.decodePolyId(ref);
        if (decoded.tile >= @as(u32, @intCast(self.max_tiles))) return error.InvalidParam;

        const tile = &self.tiles[decoded.tile];
        if (tile.salt != decoded.salt or tile.header == null) return error.InvalidParam;
        if (decoded.poly >= @as(u32, @intCast(tile.header.?.poly_count))) return error.InvalidParam;

        const poly = &tile.polys[decoded.poly];

        // Collect vertices
        var verts: [common.VERTS_PER_POLYGON * 3]f32 = undefined;
        var edge_dist: [common.VERTS_PER_POLYGON]f32 = undefined;
        var edge_t: [common.VERTS_PER_POLYGON]f32 = undefined;

        for (0..poly.vert_count) |i| {
            const v_idx = poly.verts[i] * 3;
            verts[i * 3 + 0] = tile.verts[v_idx + 0];
            verts[i * 3 + 1] = tile.verts[v_idx + 1];
            verts[i * 3 + 2] = tile.verts[v_idx + 2];
        }

        const inside = math.distancePtPolyEdgesSqr(pos, verts[0 .. poly.vert_count * 3], poly.vert_count, &edge_dist, &edge_t);

        if (inside) {
            // Point is inside the polygon, return the point
            math.vcopy(closest, pos);
        } else {
            // Point is outside, clamp to nearest edge
            var dmin = edge_dist[0];
            var imin: usize = 0;
            for (1..poly.vert_count) |i| {
                if (edge_dist[i] < dmin) {
                    dmin = edge_dist[i];
                    imin = i;
                }
            }

            const va = verts[imin * 3 .. imin * 3 + 3];
            const vb = verts[((imin + 1) % poly.vert_count) * 3 .. ((imin + 1) % poly.vert_count) * 3 + 3];
            math.vlerp(closest, va[0..3], vb[0..3], edge_t[imin]);
        }
    }

    /// Get portal points between two connected polygons
    pub fn getPortalPoints(
        self: *const Self,
        from_ref: PolyRef,
        from_poly: *const Poly,
        from_tile: *const MeshTile,
        to_ref: PolyRef,
        to_poly: *const Poly,
        to_tile: *const MeshTile,
        left: *[3]f32,
        right: *[3]f32,
    ) !void {
        _ = self;
        // Find the link that points to the 'to' polygon
        var link: ?*const Link = null;
        var i = from_poly.first_link;
        while (i != common.NULL_LINK) : (i = from_tile.links[i].next) {
            if (from_tile.links[i].ref == to_ref) {
                link = &from_tile.links[i];
                break;
            }
        }

        if (link == null) return error.InvalidParam;
        const lnk = link.?;

        // Handle off-mesh connections
        if (from_poly.getType() == .offmesh_connection) {
            // Find link that points to first vertex
            var j = from_poly.first_link;
            while (j != common.NULL_LINK) : (j = from_tile.links[j].next) {
                if (from_tile.links[j].ref == to_ref) {
                    const v = from_tile.links[j].edge;
                    const v_idx = from_poly.verts[v] * 3;
                    math.vcopy(left, from_tile.verts[v_idx .. v_idx + 3][0..3]);
                    math.vcopy(right, from_tile.verts[v_idx .. v_idx + 3][0..3]);
                    return;
                }
            }
            return error.InvalidParam;
        }

        if (to_poly.getType() == .offmesh_connection) {
            var j = to_poly.first_link;
            while (j != common.NULL_LINK) : (j = to_tile.links[j].next) {
                if (to_tile.links[j].ref == from_ref) {
                    const v = to_tile.links[j].edge;
                    const v_idx = to_poly.verts[v] * 3;
                    math.vcopy(left, to_tile.verts[v_idx .. v_idx + 3][0..3]);
                    math.vcopy(right, to_tile.verts[v_idx .. v_idx + 3][0..3]);
                    return;
                }
            }
            return error.InvalidParam;
        }

        // Find portal vertices (edge between from and to)
        const v0 = from_poly.verts[lnk.edge];
        const v1 = from_poly.verts[(lnk.edge + 1) % from_poly.vert_count];

        const v0_idx = v0 * 3;
        const v1_idx = v1 * 3;

        math.vcopy(left, from_tile.verts[v0_idx .. v0_idx + 3][0..3]);
        math.vcopy(right, from_tile.verts[v1_idx .. v1_idx + 3][0..3]);

        // If the link is at tile boundary, clamp the vertices to the link width
        if (lnk.side != 0xff) {
            if (lnk.bmin != 0 or lnk.bmax != 255) {
                const s = 1.0 / 255.0;
                const tmin = @as(f32, @floatFromInt(lnk.bmin)) * s;
                const tmax = @as(f32, @floatFromInt(lnk.bmax)) * s;

                const v0_slice = from_tile.verts[v0_idx .. v0_idx + 3];
                const v1_slice = from_tile.verts[v1_idx .. v1_idx + 3];

                math.vlerp(left, v0_slice[0..3], v1_slice[0..3], tmin);
                math.vlerp(right, v0_slice[0..3], v1_slice[0..3], tmax);
            }
        }
    }

    /// Get edge mid point between two connected polygons
    pub fn getEdgeMidPoint(
        self: *const Self,
        from_ref: PolyRef,
        from_poly: *const Poly,
        from_tile: *const MeshTile,
        to_ref: PolyRef,
        to_poly: *const Poly,
        to_tile: *const MeshTile,
        mid: *[3]f32,
    ) !void {
        var left: [3]f32 = undefined;
        var right: [3]f32 = undefined;

        try self.getPortalPoints(from_ref, from_poly, from_tile, to_ref, to_poly, to_tile, &left, &right);

        mid[0] = (left[0] + right[0]) * 0.5;
        mid[1] = (left[1] + right[1]) * 0.5;
        mid[2] = (left[2] + right[2]) * 0.5;
    }

    /// Get the endpoints of an off-mesh connection poly, ordered so that
    /// 'start' is the point that is linked to the normal polygon and 'end'
    /// is the destination point
    pub fn getOffMeshConnectionPolyEndPoints(
        self: *const Self,
        prev_ref: PolyRef,
        poly_ref: PolyRef,
        start_pos: *[3]f32,
        end_pos: *[3]f32,
    ) !void {
        if (poly_ref == 0) return error.InvalidParam;

        // Decode poly reference
        const decoded = self.decodePolyId(poly_ref);
        if (decoded.tile >= @as(u32, @intCast(self.max_tiles))) return error.InvalidParam;

        const tile = &self.tiles[decoded.tile];
        if (tile.salt != decoded.salt or tile.header == null) return error.InvalidParam;
        if (decoded.poly >= @as(u32, @intCast(tile.header.?.poly_count))) return error.InvalidParam;

        const poly = &tile.polys[decoded.poly];

        // Make sure the current poly is indeed an off-mesh link
        if (poly.getType() != .offmesh_connection) return error.InvalidParam;

        // Figure out which way to hand out the vertices
        var idx0: usize = 0;
        var idx1: usize = 1;

        // Find link that points to first vertex (edge 0)
        var i = poly.first_link;
        while (i != common.NULL_LINK) : (i = tile.links[i].next) {
            if (tile.links[i].edge == 0) {
                // If this link doesn't point to prevRef, swap the order
                if (tile.links[i].ref != prev_ref) {
                    idx0 = 1;
                    idx1 = 0;
                }
                break;
            }
        }

        // Copy vertex positions
        const v0 = poly.verts[idx0] * 3;
        const v1 = poly.verts[idx1] * 3;

        start_pos[0] = tile.verts[v0 + 0];
        start_pos[1] = tile.verts[v0 + 1];
        start_pos[2] = tile.verts[v0 + 2];

        end_pos[0] = tile.verts[v1 + 0];
        end_pos[1] = tile.verts[v1 + 1];
        end_pos[2] = tile.verts[v1 + 2];
    }
};

test "NavMesh initialization" {
    const allocator = std.testing.allocator;

    var params = NavMeshParams.init();
    params.orig = Vec3.init(0, 0, 0);
    params.tile_width = 32;
    params.tile_height = 32;
    params.max_tiles = 256;
    params.max_polys = 8192;

    var navmesh = try NavMesh.init(allocator, params);
    defer navmesh.deinit();

    try std.testing.expectEqual(@as(i32, 256), navmesh.max_tiles);
}

test "NavMesh polyRef encoding/decoding" {
    const allocator = std.testing.allocator;

    var params = NavMeshParams.init();
    params.orig = Vec3.init(0, 0, 0);
    params.tile_width = 32;
    params.tile_height = 32;
    params.max_tiles = 256;
    params.max_polys = 8192;

    var navmesh = try NavMesh.init(allocator, params);
    defer navmesh.deinit();

    const salt: u32 = 5;
    const tile: u32 = 10;
    const poly: u32 = 100;

    const ref = navmesh.encodePolyId(salt, tile, poly);
    const decoded = navmesh.decodePolyId(ref);

    try std.testing.expectEqual(salt, decoded.salt);
    try std.testing.expectEqual(tile, decoded.tile);
    try std.testing.expectEqual(poly, decoded.poly);
}

test "NavMesh tile location calculation" {
    const allocator = std.testing.allocator;

    var params = NavMeshParams.init();
    params.orig = Vec3.init(0, 0, 0);
    params.tile_width = 32;
    params.tile_height = 32;
    params.max_tiles = 256;
    params.max_polys = 8192;

    var navmesh = try NavMesh.init(allocator, params);
    defer navmesh.deinit();

    const pos = Vec3.init(64.5, 0, 96.5);
    const loc = navmesh.calcTileLoc(pos);

    try std.testing.expectEqual(@as(i32, 2), loc.x);
    try std.testing.expectEqual(@as(i32, 3), loc.y);
}
