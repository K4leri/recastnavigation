const std = @import("std");
const math = @import("../math.zig");
const common = @import("../detour/common.zig");

// Constants
pub const TILECACHE_MAGIC: i32 = ('D' << 24) | ('T' << 16) | ('L' << 8) | 'R';
pub const TILECACHE_VERSION: i32 = 1;

pub const TILECACHE_NULL_AREA: u8 = 0;
pub const TILECACHE_WALKABLE_AREA: u8 = 63;
pub const TILECACHE_NULL_IDX: u16 = 0xffff;

const MAX_VERTS_PER_POLY: usize = 6;
const MAX_REM_EDGES: usize = 48;
const LAYER_MAX_NEIS: usize = 16;

/// Tile cache layer header
pub const TileCacheLayerHeader = struct {
    magic: i32,                // Data magic
    version: i32,              // Data version
    tx: i32,                   // Tile X coordinate
    ty: i32,                   // Tile Y coordinate
    tlayer: i32,               // Tile layer
    bmin: [3]f32,              // Bounding box min
    bmax: [3]f32,              // Bounding box max
    hmin: u16,                 // Height min range
    hmax: u16,                 // Height max range
    width: u8,                 // Dimension of the layer
    height: u8,                // Dimension of the layer
    minx: u8,                  // Usable sub-region
    maxx: u8,                  // Usable sub-region
    miny: u8,                  // Usable sub-region
    maxy: u8,                  // Usable sub-region
};

/// Tile cache layer
pub const TileCacheLayer = struct {
    header: *TileCacheLayerHeader,
    reg_count: u8,             // Region count
    heights: []u8,             // Height values
    areas: []u8,               // Area IDs
    cons: []u8,                // Connectivity
    regs: []u8,                // Region IDs

    pub fn deinit(self: *TileCacheLayer, allocator: std.mem.Allocator) void {
        allocator.destroy(self.header);
        allocator.free(self.heights);
        allocator.free(self.areas);
        allocator.free(self.cons);
        allocator.free(self.regs);
    }
};

/// Tile cache contour
pub const TileCacheContour = struct {
    nverts: usize,
    verts: []u8,
    reg: u8,
    area: u8,
};

/// Tile cache contour set
pub const TileCacheContourSet = struct {
    conts: []TileCacheContour,

    pub fn deinit(self: *TileCacheContourSet, allocator: std.mem.Allocator) void {
        for (self.conts) |*cont| {
            allocator.free(cont.verts);
        }
        allocator.free(self.conts);
    }
};

/// Tile cache polygon mesh
pub const TileCachePolyMesh = struct {
    nvp: usize,                // Max verts per polygon
    nverts: usize,             // Number of vertices
    npolys: usize,             // Number of polygons
    verts: []u16,              // Vertices (3 elements per vertex)
    polys: []u16,              // Polygons (nvp*2 elements per polygon)
    flags: []u16,              // Per polygon flags
    areas: []u8,               // Area ID of polygons

    pub fn deinit(self: *TileCachePolyMesh, allocator: std.mem.Allocator) void {
        allocator.free(self.verts);
        allocator.free(self.polys);
        allocator.free(self.flags);
        allocator.free(self.areas);
    }
};

/// Compressor interface - user must provide implementation
pub const TileCacheCompressor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        maxCompressedSize: *const fn (ptr: *anyopaque, buffer_size: usize) usize,
        compress: *const fn (
            ptr: *anyopaque,
            buffer: []const u8,
            compressed: []u8,
            compressed_size: *usize,
        ) common.Status,
        decompress: *const fn (
            ptr: *anyopaque,
            compressed: []const u8,
            buffer: []u8,
            buffer_size: *usize,
        ) common.Status,
    };

    pub fn maxCompressedSize(self: *TileCacheCompressor, buffer_size: usize) usize {
        return self.vtable.maxCompressedSize(self.ptr, buffer_size);
    }

    pub fn compress(
        self: *TileCacheCompressor,
        buffer: []const u8,
        compressed: []u8,
        compressed_size: *usize,
    ) common.Status {
        return self.vtable.compress(self.ptr, buffer, compressed, compressed_size);
    }

    pub fn decompress(
        self: *TileCacheCompressor,
        compressed: []const u8,
        buffer: []u8,
        buffer_size: *usize,
    ) common.Status {
        return self.vtable.decompress(self.ptr, compressed, buffer, buffer_size);
    }
};

// Helper structures for region building

const LayerSweepSpan = struct {
    ns: u16,        // number samples
    id: u8,         // region id
    nei: u8,        // neighbour id
};

const LayerMonotoneRegion = struct {
    area: i32,
    neis: [LAYER_MAX_NEIS]u8,
    nneis: u8,
    reg_id: u8,
    area_id: u8,
};

const TempContour = struct {
    verts: []u8,
    nverts: usize,
    poly: []u16,
    npoly: usize,
};

// Helper functions

inline fn getDirOffsetX(dir: u8) i32 {
    const offset = [4]i32{ -1, 0, 1, 0 };
    return offset[dir & 0x03];
}

inline fn getDirOffsetY(dir: u8) i32 {
    const offset = [4]i32{ 0, 1, 0, -1 };
    return offset[dir & 0x03];
}

inline fn overlapRangeExl(amin: u16, amax: u16, bmin: u16, bmax: u16) bool {
    return !(amin >= bmax or amax <= bmin);
}

fn addUniqueLast(a: []u8, an: *u8, v: u8) void {
    const n = an.*;
    if (n > 0 and a[n - 1] == v) return;
    a[n] = v;
    an.* += 1;
}

fn isConnected(layer: *const TileCacheLayer, ia: usize, ib: usize, walkable_climb: i32) bool {
    if (layer.areas[ia] != layer.areas[ib]) return false;
    if (@abs(@as(i32, layer.heights[ia]) - @as(i32, layer.heights[ib])) > walkable_climb) return false;
    return true;
}

fn canMerge(old_reg_id: u8, new_reg_id: u8, regs: []const LayerMonotoneRegion) bool {
    var count: usize = 0;
    for (regs) |*reg| {
        if (reg.reg_id != old_reg_id) continue;
        const nnei = reg.nneis;
        for (0..nnei) |j| {
            if (regs[reg.neis[j]].reg_id == new_reg_id) {
                count += 1;
            }
        }
    }
    return count == 1;
}

/// Allocate a new tile cache contour set
pub fn allocTileCacheContourSet(allocator: std.mem.Allocator) !*TileCacheContourSet {
    const cset = try allocator.create(TileCacheContourSet);
    cset.* = TileCacheContourSet{
        .conts = &[_]TileCacheContour{},
    };
    return cset;
}

/// Free a tile cache contour set
pub fn freeTileCacheContourSet(allocator: std.mem.Allocator, cset: *TileCacheContourSet) void {
    cset.deinit(allocator);
    allocator.destroy(cset);
}

/// Allocate a new tile cache polygon mesh
pub fn allocTileCachePolyMesh(allocator: std.mem.Allocator) !*TileCachePolyMesh {
    const lmesh = try allocator.create(TileCachePolyMesh);
    lmesh.* = TileCachePolyMesh{
        .nvp = 0,
        .nverts = 0,
        .npolys = 0,
        .verts = &[_]u16{},
        .polys = &[_]u16{},
        .flags = &[_]u16{},
        .areas = &[_]u8{},
    };
    return lmesh;
}

/// Free a tile cache polygon mesh
pub fn freeTileCachePolyMesh(allocator: std.mem.Allocator, lmesh: *TileCachePolyMesh) void {
    lmesh.deinit(allocator);
    allocator.destroy(lmesh);
}

/// Free a tile cache layer
pub fn freeTileCacheLayer(allocator: std.mem.Allocator, layer: *TileCacheLayer) void {
    layer.deinit(allocator);
    allocator.destroy(layer);
}

/// Build tile cache regions using monotone partitioning
pub fn buildTileCacheRegions(
    allocator: std.mem.Allocator,
    layer: *TileCacheLayer,
    walkable_climb: i32,
) !common.Status {
    const w = @as(usize, layer.header.width);
    const h = @as(usize, layer.header.height);

    // Reset regions
    @memset(layer.regs, 0xff);

    // Allocate sweep spans
    const nsweeps = w;
    var sweeps = try allocator.alloc(LayerSweepSpan, nsweeps);
    defer allocator.free(sweeps);
    @memset(sweeps, LayerSweepSpan{ .ns = 0, .id = 0, .nei = 0xff });

    // Partition walkable area into monotone regions
    var prev_count: [256]u8 = undefined;
    var reg_id: u8 = 0;

    for (0..h) |y| {
        if (reg_id > 0) {
            @memset(prev_count[0..reg_id], 0);
        }
        var sweep_id: u8 = 0;

        for (0..w) |x| {
            const idx = x + y * w;
            if (layer.areas[idx] == TILECACHE_NULL_AREA) continue;

            var sid: u8 = 0xff;

            // Check -x neighbor
            if (x > 0) {
                const xidx = (x - 1) + y * w;
                if (isConnected(layer, idx, xidx, walkable_climb)) {
                    if (layer.regs[xidx] != 0xff) {
                        sid = layer.regs[xidx];
                    }
                }
            }

            if (sid == 0xff) {
                sid = sweep_id;
                sweep_id += 1;
                sweeps[sid].nei = 0xff;
                sweeps[sid].ns = 0;
            }

            // Check -y neighbor
            if (y > 0) {
                const yidx = x + (y - 1) * w;
                if (isConnected(layer, idx, yidx, walkable_climb)) {
                    const nr = layer.regs[yidx];
                    if (nr != 0xff) {
                        // Set neighbour when first valid neighbour is encountered
                        if (sweeps[sid].ns == 0) {
                            sweeps[sid].nei = nr;
                        }

                        if (sweeps[sid].nei == nr) {
                            // Update existing neighbour
                            sweeps[sid].ns += 1;
                            prev_count[nr] += 1;
                        } else {
                            // Multiple neighbours - invalidate
                            sweeps[sid].nei = 0xff;
                        }
                    }
                }
            }

            layer.regs[idx] = sid;
        }

        // Create unique IDs
        for (0..sweep_id) |i| {
            // Merge with previous region if continuous connection
            if (sweeps[i].nei != 0xff and prev_count[sweeps[i].nei] == sweeps[i].ns) {
                sweeps[i].id = sweeps[i].nei;
            } else {
                if (reg_id == 255) {
                    // Region ID overflow
                    return common.Status{ .failure = true, .buffer_too_small = true };
                }
                sweeps[i].id = reg_id;
                reg_id += 1;
            }
        }

        // Remap local sweep ids to region ids
        for (0..w) |x| {
            const idx = x + y * w;
            if (layer.regs[idx] != 0xff) {
                layer.regs[idx] = sweeps[layer.regs[idx]].id;
            }
        }
    }

    // Allocate and init layer regions
    const nregs = @as(usize, reg_id);
    var regs = try allocator.alloc(LayerMonotoneRegion, nregs);
    defer allocator.free(regs);

    @memset(regs, LayerMonotoneRegion{
        .area = 0,
        .neis = [_]u8{0} ** LAYER_MAX_NEIS,
        .nneis = 0,
        .reg_id = 0,
        .area_id = 0,
    });

    for (0..nregs) |i| {
        regs[i].reg_id = @intCast(i);
    }

    // Find region neighbours and update areas
    for (0..h) |y| {
        for (0..w) |x| {
            const idx = x + y * w;
            const ri = layer.regs[idx];
            if (ri == 0xff) continue;

            // Update area
            regs[ri].area += 1;
            regs[ri].area_id = layer.areas[idx];

            // Update neighbours (check -y direction)
            if (y > 0) {
                const yidx = x + (y - 1) * w;
                if (isConnected(layer, idx, yidx, walkable_climb)) {
                    const rai = layer.regs[yidx];
                    if (rai != 0xff and rai != ri) {
                        addUniqueLast(&regs[ri].neis, &regs[ri].nneis, rai);
                        addUniqueLast(&regs[rai].neis, &regs[rai].nneis, ri);
                    }
                }
            }
        }
    }

    for (0..nregs) |i| {
        regs[i].reg_id = @intCast(i);
    }

    // Merge regions
    for (0..nregs) |i| {
        const reg = &regs[i];

        var merge: i32 = -1;
        var merge_area: i32 = 0;

        for (0..reg.nneis) |j| {
            const nei = reg.neis[j];
            const regn = &regs[nei];

            if (reg.reg_id == regn.reg_id) continue;
            if (reg.area_id != regn.area_id) continue;

            if (regn.area > merge_area) {
                if (canMerge(reg.reg_id, regn.reg_id, regs)) {
                    merge_area = regn.area;
                    merge = @intCast(nei);
                }
            }
        }

        if (merge != -1) {
            const old_id = reg.reg_id;
            const new_id = regs[@intCast(merge)].reg_id;
            for (0..nregs) |j| {
                if (regs[j].reg_id == old_id) {
                    regs[j].reg_id = new_id;
                }
            }
        }
    }

    // Compact region IDs
    var remap: [256]u8 = undefined;
    @memset(&remap, 0);

    // Find number of unique regions
    reg_id = 0;
    for (0..nregs) |i| {
        remap[regs[i].reg_id] = 1;
    }
    for (0..256) |i| {
        if (remap[i] != 0) {
            remap[i] = reg_id;
            reg_id += 1;
        }
    }

    // Remap region IDs
    for (0..nregs) |i| {
        regs[i].reg_id = remap[regs[i].reg_id];
    }

    layer.reg_count = reg_id;

    // Apply remapped IDs to layer
    for (0..w * h) |i| {
        if (layer.regs[i] != 0xff) {
            layer.regs[i] = regs[layer.regs[i]].reg_id;
        }
    }

    return common.Status{ .success = true };
}

/// Decompress a tile cache layer
pub fn decompressTileCacheLayer(
    allocator: std.mem.Allocator,
    comp: *TileCacheCompressor,
    compressed: []const u8,
) !*TileCacheLayer {
    // Read header
    if (compressed.len < @sizeOf(TileCacheLayerHeader)) {
        return error.InvalidData;
    }

    const header = try allocator.create(TileCacheLayerHeader);
    errdefer allocator.destroy(header);

    // Copy header from compressed data
    const header_bytes = compressed[0..@sizeOf(TileCacheLayerHeader)];
    @memcpy(std.mem.asBytes(header), header_bytes);

    // Validate header
    if (header.magic != TILECACHE_MAGIC) {
        return error.WrongMagic;
    }
    if (header.version != TILECACHE_VERSION) {
        return error.WrongVersion;
    }

    const w = @as(usize, header.width);
    const h = @as(usize, header.height);
    const grid_size = w * h;

    // Allocate layer data
    const heights = try allocator.alloc(u8, grid_size);
    errdefer allocator.free(heights);

    const areas = try allocator.alloc(u8, grid_size);
    errdefer allocator.free(areas);

    const cons = try allocator.alloc(u8, grid_size);
    errdefer allocator.free(cons);

    const regs = try allocator.alloc(u8, grid_size);
    errdefer allocator.free(regs);

    // Decompress data
    const comp_data = compressed[@sizeOf(TileCacheLayerHeader)..];
    const buffer_size = grid_size * 4; // heights + areas + cons + regs
    var decomp_buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(decomp_buffer);

    var decomp_size: usize = 0;
    const status = comp.decompress(comp_data, decomp_buffer, &decomp_size);
    if (!status.success) {
        return error.DecompressionFailed;
    }

    // Copy decompressed data
    @memcpy(heights, decomp_buffer[0..grid_size]);
    @memcpy(areas, decomp_buffer[grid_size .. 2 * grid_size]);
    @memcpy(cons, decomp_buffer[2 * grid_size .. 3 * grid_size]);
    @memset(regs, 0xff); // Regions are computed, not stored

    const layer = try allocator.create(TileCacheLayer);
    layer.* = TileCacheLayer{
        .header = header,
        .reg_count = 0,
        .heights = heights,
        .areas = areas,
        .cons = cons,
        .regs = regs,
    };

    return layer;
}

/// Build a compressed tile cache layer
pub fn buildTileCacheLayer(
    comp: *TileCacheCompressor,
    header: *const TileCacheLayerHeader,
    heights: []const u8,
    areas: []const u8,
    cons: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    const w = @as(usize, header.width);
    const h = @as(usize, header.height);
    const grid_size = w * h;

    // Combine data to compress
    const buffer_size = grid_size * 3; // heights + areas + cons
    var buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(buffer);

    @memcpy(buffer[0..grid_size], heights);
    @memcpy(buffer[grid_size .. 2 * grid_size], areas);
    @memcpy(buffer[2 * grid_size .. 3 * grid_size], cons);

    // Allocate compressed buffer
    const max_comp_size = comp.maxCompressedSize(buffer_size);
    const total_size = @sizeOf(TileCacheLayerHeader) + max_comp_size;
    var data = try allocator.alloc(u8, total_size);
    errdefer allocator.free(data);

    // Copy header
    @memcpy(data[0..@sizeOf(TileCacheLayerHeader)], std.mem.asBytes(header));

    // Compress data
    var comp_size: usize = 0;
    const status = comp.compress(
        buffer,
        data[@sizeOf(TileCacheLayerHeader)..],
        &comp_size,
    );

    if (!status.success) {
        allocator.free(data);
        return error.CompressionFailed;
    }

    // Resize to actual compressed size
    const final_size = @sizeOf(TileCacheLayerHeader) + comp_size;
    if (final_size < total_size) {
        data = try allocator.realloc(data, final_size);
    }

    return data;
}

/// Mark cylinder area in a layer
pub fn markCylinderArea(
    layer: *TileCacheLayer,
    orig: *const [3]f32,
    cs: f32,
    ch: f32,
    pos: *const [3]f32,
    radius: f32,
    height: f32,
    area_id: u8,
) common.Status {
    // Calculate bounding box
    const bmin = [3]f32{
        pos[0] - radius,
        pos[1],
        pos[2] - radius,
    };
    const bmax = [3]f32{
        pos[0] + radius,
        pos[1] + height,
        pos[2] + radius,
    };

    const r2 = math.sqr(f32, radius / cs + 0.5);

    const w = @as(i32, layer.header.width);
    const h = @as(i32, layer.header.height);
    const ics = 1.0 / cs;
    const ich = 1.0 / ch;

    const px = (pos[0] - orig[0]) * ics;
    const pz = (pos[2] - orig[2]) * ics;

    var minx = @as(i32, @intFromFloat(@floor((bmin[0] - orig[0]) * ics)));
    const miny = @as(i32, @intFromFloat(@floor((bmin[1] - orig[1]) * ich)));
    var minz = @as(i32, @intFromFloat(@floor((bmin[2] - orig[2]) * ics)));
    var maxx = @as(i32, @intFromFloat(@floor((bmax[0] - orig[0]) * ics)));
    const maxy = @as(i32, @intFromFloat(@floor((bmax[1] - orig[1]) * ich)));
    var maxz = @as(i32, @intFromFloat(@floor((bmax[2] - orig[2]) * ics)));

    // Early out if completely outside
    if (maxx < 0) return common.Status{ .success = true };
    if (minx >= w) return common.Status{ .success = true };
    if (maxz < 0) return common.Status{ .success = true };
    if (minz >= h) return common.Status{ .success = true };

    // Clamp to grid
    if (minx < 0) minx = 0;
    if (maxx >= w) maxx = w - 1;
    if (minz < 0) minz = 0;
    if (maxz >= h) maxz = h - 1;

    // Mark cells within cylinder
    var z = minz;
    while (z <= maxz) : (z += 1) {
        var x = minx;
        while (x <= maxx) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - px;
            const dz = @as(f32, @floatFromInt(z)) + 0.5 - pz;
            if (dx * dx + dz * dz > r2) continue;

            const idx = @as(usize, @intCast(x + z * w));
            const y = @as(i32, layer.heights[idx]);
            if (y < miny or y > maxy) continue;

            layer.areas[idx] = area_id;
        }
    }

    return common.Status{ .success = true };
}

/// Mark AABB box area in a layer
pub fn markBoxArea(
    layer: *TileCacheLayer,
    orig: *const [3]f32,
    cs: f32,
    ch: f32,
    bmin: *const [3]f32,
    bmax: *const [3]f32,
    area_id: u8,
) common.Status {
    const w = @as(i32, layer.header.width);
    const h = @as(i32, layer.header.height);
    const ics = 1.0 / cs;
    const ich = 1.0 / ch;

    var minx = @as(i32, @intFromFloat(@floor((bmin[0] - orig[0]) * ics)));
    const miny = @as(i32, @intFromFloat(@floor((bmin[1] - orig[1]) * ich)));
    var minz = @as(i32, @intFromFloat(@floor((bmin[2] - orig[2]) * ics)));
    var maxx = @as(i32, @intFromFloat(@floor((bmax[0] - orig[0]) * ics)));
    const maxy = @as(i32, @intFromFloat(@floor((bmax[1] - orig[1]) * ich)));
    var maxz = @as(i32, @intFromFloat(@floor((bmax[2] - orig[2]) * ics)));

    // Early out if completely outside
    if (maxx < 0) return common.Status{ .success = true };
    if (minx >= w) return common.Status{ .success = true };
    if (maxz < 0) return common.Status{ .success = true };
    if (minz >= h) return common.Status{ .success = true };

    // Clamp to grid
    if (minx < 0) minx = 0;
    if (maxx >= w) maxx = w - 1;
    if (minz < 0) minz = 0;
    if (maxz >= h) maxz = h - 1;

    // Mark cells within box
    var z = minz;
    while (z <= maxz) : (z += 1) {
        var x = minx;
        while (x <= maxx) : (x += 1) {
            const idx = @as(usize, @intCast(x + z * w));
            const y = @as(i32, layer.heights[idx]);
            if (y < miny or y > maxy) continue;

            layer.areas[idx] = area_id;
        }
    }

    return common.Status{ .success = true };
}

/// Mark oriented box (OBB) area in a layer
pub fn markOrientedBoxArea(
    layer: *TileCacheLayer,
    orig: *const [3]f32,
    cs: f32,
    ch: f32,
    center: *const [3]f32,
    half_extents: *const [3]f32,
    rot_aux: *const [2]f32,
    area_id: u8,
) common.Status {
    const w = @as(i32, layer.header.width);
    const h = @as(i32, layer.header.height);
    const ics = 1.0 / cs;
    const ich = 1.0 / ch;

    const cx = (center[0] - orig[0]) * ics;
    const cz = (center[2] - orig[2]) * ics;

    const maxr = 1.41 * @max(half_extents[0], half_extents[2]);
    var minx = @as(i32, @intFromFloat(@floor(cx - maxr * ics)));
    var maxx = @as(i32, @intFromFloat(@floor(cx + maxr * ics)));
    var minz = @as(i32, @intFromFloat(@floor(cz - maxr * ics)));
    var maxz = @as(i32, @intFromFloat(@floor(cz + maxr * ics)));
    const miny = @as(i32, @intFromFloat(@floor((center[1] - half_extents[1] - orig[1]) * ich)));
    const maxy = @as(i32, @intFromFloat(@floor((center[1] + half_extents[1] - orig[1]) * ich)));

    // Early out if completely outside
    if (maxx < 0) return common.Status{ .success = true };
    if (minx >= w) return common.Status{ .success = true };
    if (maxz < 0) return common.Status{ .success = true };
    if (minz >= h) return common.Status{ .success = true };

    // Clamp to grid
    if (minx < 0) minx = 0;
    if (maxx >= w) maxx = w - 1;
    if (minz < 0) minz = 0;
    if (maxz >= h) maxz = h - 1;

    const xhalf = half_extents[0] * ics + 0.5;
    const zhalf = half_extents[2] * ics + 0.5;

    // Mark cells within oriented box
    var z = minz;
    while (z <= maxz) : (z += 1) {
        var x = minx;
        while (x <= maxx) : (x += 1) {
            const x2 = 2.0 * (@as(f32, @floatFromInt(x)) - cx);
            const z2 = 2.0 * (@as(f32, @floatFromInt(z)) - cz);
            const xrot = rot_aux[1] * x2 + rot_aux[0] * z2;
            if (xrot > xhalf or xrot < -xhalf) continue;
            const zrot = rot_aux[1] * z2 - rot_aux[0] * x2;
            if (zrot > zhalf or zrot < -zhalf) continue;

            const idx = @as(usize, @intCast(x + z * w));
            const y = @as(i32, layer.heights[idx]);
            if (y < miny or y > maxy) continue;

            layer.areas[idx] = area_id;
        }
    }

    return common.Status{ .success = true };
}

// Helper function to get neighbour region
fn getNeighbourReg(layer: *const TileCacheLayer, ax: i32, ay: i32, dir: u8) u8 {
    const w = @as(i32, layer.header.width);
    const ia = @as(usize, @intCast(ax + ay * w));

    const con = layer.cons[ia] & 0xf;
    const portal = layer.cons[ia] >> 4;
    const mask: u8 = @as(u8, 1) << @intCast(dir);

    if ((con & mask) == 0) {
        // No connection, return portal or hard edge
        if ((portal & mask) != 0) {
            return 0xf8 + dir;
        }
        return 0xff;
    }

    const bx = ax + getDirOffsetX(dir);
    const by = ay + getDirOffsetY(dir);
    const ib = @as(usize, @intCast(bx + by * w));

    return layer.regs[ib];
}

// Helper function to append vertex to contour
fn appendVertex(cont: *TempContour, x: i32, y: i32, z: i32, r: u8) bool {
    // Try to merge with existing segments
    if (cont.nverts > 1) {
        const pa = cont.verts[(cont.nverts - 2) * 4 ..];
        const pb = cont.verts[(cont.nverts - 1) * 4 ..];
        if (pb[3] == r) {
            if (pa[0] == pb[0] and pb[0] == @as(u8, @intCast(x))) {
                // Aligned along x-axis, update z
                const idx = (cont.nverts - 1) * 4;
                cont.verts[idx + 1] = @intCast(y);
                cont.verts[idx + 2] = @intCast(z);
                return true;
            } else if (pa[2] == pb[2] and pb[2] == @as(u8, @intCast(z))) {
                // Aligned along z-axis, update x
                const idx = (cont.nverts - 1) * 4;
                cont.verts[idx + 0] = @intCast(x);
                cont.verts[idx + 1] = @intCast(y);
                return true;
            }
        }
    }

    // Add new point
    if (cont.nverts + 1 > cont.verts.len / 4) {
        return false;
    }

    const idx = cont.nverts * 4;
    cont.verts[idx + 0] = @intCast(x);
    cont.verts[idx + 1] = @intCast(y);
    cont.verts[idx + 2] = @intCast(z);
    cont.verts[idx + 3] = r;
    cont.nverts += 1;

    return true;
}

// Walk contour around region
fn walkContour(layer: *const TileCacheLayer, start_x: i32, start_y: i32, cont: *TempContour) bool {
    const w = @as(i32, layer.header.width);
    const h = @as(i32, layer.header.height);

    cont.nverts = 0;

    var x = start_x;
    var y = start_y;
    var start_dir: i32 = -1;

    // Find start direction
    for (0..4) |i| {
        const dir: u8 = @intCast((i + 3) & 3);
        const rn = getNeighbourReg(layer, x, y, dir);
        const idx = @as(usize, @intCast(x + y * w));
        if (rn != layer.regs[idx]) {
            start_dir = @intCast(dir);
            break;
        }
    }

    if (start_dir == -1) {
        return true;
    }

    var dir: i32 = start_dir;
    const max_iter = @as(usize, @intCast(w * h));
    var iter: usize = 0;

    while (iter < max_iter) : (iter += 1) {
        const rn = getNeighbourReg(layer, x, y, @intCast(dir));
        const idx = @as(usize, @intCast(x + y * w));

        var nx = x;
        var ny = y;
        var ndir = dir;

        if (rn != layer.regs[idx]) {
            // Solid edge
            var px = x;
            var pz = y;
            switch (dir) {
                0 => pz += 1,
                1 => {
                    px += 1;
                    pz += 1;
                },
                2 => px += 1,
                else => {},
            }

            // Try to merge with previous vertex
            const lh = @as(i32, layer.heights[idx]);
            if (!appendVertex(cont, px, lh, pz, rn)) {
                return false;
            }

            ndir = (dir + 1) & 0x3; // Rotate CW
        } else {
            // Move to next
            nx = x + getDirOffsetX(@intCast(dir));
            ny = y + getDirOffsetY(@intCast(dir));
            ndir = (dir + 3) & 0x3; // Rotate CCW
        }

        if (iter > 0 and x == start_x and y == start_y and dir == start_dir) {
            break;
        }

        x = nx;
        y = ny;
        dir = ndir;
    }

    // Remove last vertex if duplicate of first
    if (cont.nverts > 0) {
        const pa = cont.verts[(cont.nverts - 1) * 4 ..];
        const pb = cont.verts[0..];
        if (pa[0] == pb[0] and pa[2] == pb[2]) {
            cont.nverts -= 1;
        }
    }

    return true;
}

// Distance from point to segment (squared)
fn distancePtSeg(x: i32, z: i32, px: i32, pz: i32, qx: i32, qz: i32) f32 {
    const pqx = @as(f32, @floatFromInt(qx - px));
    const pqz = @as(f32, @floatFromInt(qz - pz));
    const dx_init = @as(f32, @floatFromInt(x - px));
    const dz_init = @as(f32, @floatFromInt(z - pz));
    const d = pqx * pqx + pqz * pqz;
    var t = pqx * dx_init + pqz * dz_init;
    if (d > 0) {
        t /= d;
    }
    if (t < 0) {
        t = 0;
    } else if (t > 1) {
        t = 1;
    }

    const dx = @as(f32, @floatFromInt(px)) + t * pqx - @as(f32, @floatFromInt(x));
    const dz = @as(f32, @floatFromInt(pz)) + t * pqz - @as(f32, @floatFromInt(z));

    return dx * dx + dz * dz;
}

// Simplify contour using Douglas-Peucker algorithm
fn simplifyContour(cont: *TempContour, max_error: f32) void {
    cont.npoly = 0;

    // Find wall transitions
    for (0..cont.nverts) |i| {
        const j = (i + 1) % cont.nverts;
        const ra = cont.verts[j * 4 + 3];
        const rb = cont.verts[i * 4 + 3];
        if (ra != rb) {
            cont.poly[cont.npoly] = @intCast(i);
            cont.npoly += 1;
        }
    }

    if (cont.npoly < 2) {
        // No transitions, create initial points
        // Find lower-left and upper-right vertices
        var llx = @as(i32, cont.verts[0]);
        var llz = @as(i32, cont.verts[2]);
        var lli: usize = 0;
        var urx = @as(i32, cont.verts[0]);
        var urz = @as(i32, cont.verts[2]);
        var uri: usize = 0;

        for (1..cont.nverts) |i| {
            const x = @as(i32, cont.verts[i * 4 + 0]);
            const z = @as(i32, cont.verts[i * 4 + 2]);
            if (x < llx or (x == llx and z < llz)) {
                llx = x;
                llz = z;
                lli = i;
            }
            if (x > urx or (x == urx and z > urz)) {
                urx = x;
                urz = z;
                uri = i;
            }
        }

        cont.npoly = 0;
        cont.poly[cont.npoly] = @intCast(lli);
        cont.npoly += 1;
        cont.poly[cont.npoly] = @intCast(uri);
        cont.npoly += 1;
    }

    // Add points until all raw points are within error tolerance
    var i: usize = 0;
    while (i < cont.npoly) {
        const ii = (i + 1) % cont.npoly;

        const ai = @as(usize, cont.poly[i]);
        const ax = @as(i32, cont.verts[ai * 4 + 0]);
        const az = @as(i32, cont.verts[ai * 4 + 2]);

        const bi = @as(usize, cont.poly[ii]);
        const bx = @as(i32, cont.verts[bi * 4 + 0]);
        const bz = @as(i32, cont.verts[bi * 4 + 2]);

        // Find maximum deviation from segment
        var maxd: f32 = 0;
        var maxi: i32 = -1;
        var ci: usize = 0;
        var cinc: usize = 0;
        var endi: usize = 0;

        // Traverse in lexicological order
        if (bx > ax or (bx == ax and bz > az)) {
            cinc = 1;
            ci = (ai + cinc) % cont.nverts;
            endi = bi;
        } else {
            cinc = cont.nverts - 1;
            ci = (bi + cinc) % cont.nverts;
            endi = ai;
        }

        while (ci != endi) {
            const cx = @as(i32, cont.verts[ci * 4 + 0]);
            const cz = @as(i32, cont.verts[ci * 4 + 2]);
            const d = distancePtSeg(cx, cz, ax, az, bx, bz);
            if (d > maxd) {
                maxd = d;
                maxi = @intCast(ci);
            }
            ci = (ci + cinc) % cont.nverts;
        }

        // If max deviation is larger than accepted error, add new point
        if (maxi != -1 and maxd > (max_error * max_error)) {
            cont.npoly += 1;
            var j = cont.npoly - 1;
            while (j > i) : (j -= 1) {
                cont.poly[j] = cont.poly[j - 1];
            }
            cont.poly[i + 1] = @intCast(maxi);
        } else {
            i += 1;
        }
    }

    // Remap vertices
    var start: usize = 0;
    for (1..cont.npoly) |idx| {
        if (cont.poly[idx] < cont.poly[start]) {
            start = idx;
        }
    }

    // Copy simplified vertices
    var temp_verts: [2048]u8 = undefined; // Temporary storage
    for (0..cont.npoly) |idx| {
        const j = (start + idx) % cont.npoly;
        const src_idx = @as(usize, cont.poly[j]) * 4;
        const dst_idx = idx * 4;
        temp_verts[dst_idx + 0] = cont.verts[src_idx + 0];
        temp_verts[dst_idx + 1] = cont.verts[src_idx + 1];
        temp_verts[dst_idx + 2] = cont.verts[src_idx + 2];
        temp_verts[dst_idx + 3] = cont.verts[src_idx + 3];
    }

    cont.nverts = cont.npoly;
    @memcpy(cont.verts[0 .. cont.nverts * 4], temp_verts[0 .. cont.nverts * 4]);
}

// Get corner height with portal detection
fn getCornerHeight(
    layer: *const TileCacheLayer,
    x: i32,
    y: i32,
    z: i32,
    walkable_climb: i32,
    should_remove: *bool,
) u8 {
    const w = @as(i32, layer.header.width);
    const h = @as(i32, layer.header.height);

    var n: i32 = 0;
    var portal: u8 = 0xf;
    var height: u8 = 0;
    var preg: u8 = 0xff;
    var all_same_reg = true;

    var dz: i32 = -1;
    while (dz <= 0) : (dz += 1) {
        var dx: i32 = -1;
        while (dx <= 0) : (dx += 1) {
            const px = x + dx;
            const pz = z + dz;
            if (px >= 0 and pz >= 0 and px < w and pz < h) {
                const idx = @as(usize, @intCast(px + pz * w));
                const lh = @as(i32, layer.heights[idx]);
                if (@abs(lh - y) <= walkable_climb and layer.areas[idx] != TILECACHE_NULL_AREA) {
                    height = @max(height, @as(u8, @intCast(lh)));
                    portal &= (layer.cons[idx] >> 4);
                    if (preg != 0xff and preg != layer.regs[idx]) {
                        all_same_reg = false;
                    }
                    preg = layer.regs[idx];
                    n += 1;
                }
            }
        }
    }

    var portal_count: i32 = 0;
    for (0..4) |dir| {
        if ((portal & (@as(u8, 1) << @intCast(dir))) != 0) {
            portal_count += 1;
        }
    }

    should_remove.* = false;
    if (n > 1 and portal_count == 1 and all_same_reg) {
        should_remove.* = true;
    }

    return height;
}

/// Build tile cache contours from regions
pub fn buildTileCacheContours(
    allocator: std.mem.Allocator,
    layer: *const TileCacheLayer,
    walkable_climb: i32,
    max_error: f32,
) !TileCacheContourSet {
    const w = @as(usize, layer.header.width);
    const h = @as(usize, layer.header.height);

    const nconts = @as(usize, layer.reg_count);
    var conts = try allocator.alloc(TileCacheContour, nconts);
    errdefer allocator.free(conts);

    @memset(conts, TileCacheContour{
        .nverts = 0,
        .verts = &[_]u8{},
        .reg = 0,
        .area = 0,
    });

    // Allocate temp buffer for contour tracing
    const max_temp_verts = (w + h) * 2 * 2;
    const temp_verts = try allocator.alloc(u8, max_temp_verts * 4);
    defer allocator.free(temp_verts);

    const temp_poly = try allocator.alloc(u16, max_temp_verts);
    defer allocator.free(temp_poly);

    var temp = TempContour{
        .verts = temp_verts,
        .nverts = 0,
        .poly = temp_poly,
        .npoly = 0,
    };

    // Find contours
    for (0..h) |y| {
        for (0..w) |x| {
            const idx = x + y * w;
            const ri = layer.regs[idx];
            if (ri == 0xff) continue;

            const cont = &conts[ri];
            if (cont.nverts > 0) continue;

            cont.reg = ri;
            cont.area = layer.areas[idx];

            if (!walkContour(layer, @intCast(x), @intCast(y), &temp)) {
                return error.BufferTooSmall;
            }

            simplifyContour(&temp, max_error);

            // Store contour
            if (temp.nverts > 0) {
                cont.verts = try allocator.alloc(u8, temp.nverts * 4);
                cont.nverts = temp.nverts;

                for (0..temp.nverts) |i| {
                    const j = if (i == 0) temp.nverts - 1 else i - 1;
                    const dst_idx = j * 4;
                    const v_idx = j * 4;
                    const vn_idx = i * 4;
                    const nei = temp.verts[vn_idx + 3]; // Neighbour reg stored at segment vertex

                    var should_remove = false;
                    const lh = getCornerHeight(
                        layer,
                        @as(i32, temp.verts[v_idx + 0]),
                        @as(i32, temp.verts[v_idx + 1]),
                        @as(i32, temp.verts[v_idx + 2]),
                        walkable_climb,
                        &should_remove,
                    );

                    cont.verts[dst_idx + 0] = temp.verts[v_idx + 0];
                    cont.verts[dst_idx + 1] = lh;
                    cont.verts[dst_idx + 2] = temp.verts[v_idx + 2];

                    // Store portal direction and remove status
                    cont.verts[dst_idx + 3] = 0x0f;
                    if (nei != 0xff and nei >= 0xf8) {
                        cont.verts[dst_idx + 3] = nei - 0xf8;
                    }
                    if (should_remove) {
                        cont.verts[dst_idx + 3] |= 0x80;
                    }
                }
            }
        }
    }

    return TileCacheContourSet{ .conts = conts };
}

// ============================================================================
// Poly Mesh Building - Vertex Deduplication
// ============================================================================

const VERTEX_BUCKET_COUNT2 = 1 << 12;

fn computeVertexHash2(x: u16, z: u16) u32 {
    const h1: u32 = 0x8da6b343; // Large multiplicative constants
    const h2: u32 = 0xd8163841;
    const n: u32 = h1 *% x +% h2 *% z;
    return n & (VERTEX_BUCKET_COUNT2 - 1);
}

fn addVertex(
    x: u16,
    y: u16,
    z: u16,
    verts: []u16,
    first_vert: []u16,
    next_vert: []u16,
    nv: *i32,
) u16 {
    const bucket = computeVertexHash2(x, z);
    var i = first_vert[bucket];

    while (i != TILECACHE_NULL_IDX) {
        const v = verts[@as(usize, i) * 3 ..];
        const y_diff = if (v[1] > y) v[1] - y else y - v[1];
        if (v[0] == x and v[2] == z and y_diff <= 2) {
            return i;
        }
        i = next_vert[i];
    }

    // Could not find, create new
    i = @intCast(nv.*);
    nv.* += 1;
    const v = verts[@as(usize, i) * 3 ..];
    v[0] = x;
    v[1] = y;
    v[2] = z;
    next_vert[i] = first_vert[bucket];
    first_vert[bucket] = i;

    return i;
}

// ============================================================================
// Geometric Helpers for Triangulation
// ============================================================================

inline fn prev(i: i32, n: i32) i32 {
    return if (i - 1 >= 0) i - 1 else n - 1;
}

inline fn next(i: i32, n: i32) i32 {
    return if (i + 1 < n) i + 1 else 0;
}

inline fn area2(a: [*]const u8, b: [*]const u8, c: [*]const u8) i32 {
    return (@as(i32, b[0]) - @as(i32, a[0])) * (@as(i32, c[2]) - @as(i32, a[2])) -
        (@as(i32, c[0]) - @as(i32, a[0])) * (@as(i32, b[2]) - @as(i32, a[2]));
}

inline fn left(a: [*]const u8, b: [*]const u8, c: [*]const u8) bool {
    return area2(a, b, c) < 0;
}

inline fn leftOn(a: [*]const u8, b: [*]const u8, c: [*]const u8) bool {
    return area2(a, b, c) <= 0;
}

inline fn collinear(a: [*]const u8, b: [*]const u8, c: [*]const u8) bool {
    return area2(a, b, c) == 0;
}

fn intersectProp(a: [*]const u8, b: [*]const u8, c: [*]const u8, d: [*]const u8) bool {
    // Eliminate improper cases
    if (collinear(a, b, c) or collinear(a, b, d) or
        collinear(c, d, a) or collinear(c, d, b))
    {
        return false;
    }

    return (left(a, b, c) != left(a, b, d)) and (left(c, d, a) != left(c, d, b));
}

fn between(a: [*]const u8, b: [*]const u8, c: [*]const u8) bool {
    if (!collinear(a, b, c)) {
        return false;
    }
    // If ab not vertical, check betweenness on x; else on y
    if (a[0] != b[0]) {
        return ((a[0] <= c[0]) and (c[0] <= b[0])) or ((a[0] >= c[0]) and (c[0] >= b[0]));
    } else {
        return ((a[2] <= c[2]) and (c[2] <= b[2])) or ((a[2] >= c[2]) and (c[2] >= b[2]));
    }
}

fn intersect(a: [*]const u8, b: [*]const u8, c: [*]const u8, d: [*]const u8) bool {
    if (intersectProp(a, b, c, d)) {
        return true;
    } else if (between(a, b, c) or between(a, b, d) or
        between(c, d, a) or between(c, d, b))
    {
        return true;
    } else {
        return false;
    }
}

inline fn vequal(a: [*]const u8, b: [*]const u8) bool {
    return a[0] == b[0] and a[2] == b[2];
}

// ============================================================================
// Triangulation Functions
// ============================================================================

fn diagonalie(i: i32, j: i32, n: i32, verts: [*]const u8, indices: []const u16) bool {
    const d0 = verts + (@as(usize, indices[@intCast(i)] & 0x7fff) * 4);
    const d1 = verts + (@as(usize, indices[@intCast(j)] & 0x7fff) * 4);

    // For each edge (k,k+1) of P
    var k: i32 = 0;
    while (k < n) : (k += 1) {
        const k1 = next(k, n);
        // Skip edges incident to i or j
        if (!((k == i) or (k1 == i) or (k == j) or (k1 == j))) {
            const p0 = verts + (@as(usize, indices[@intCast(k)] & 0x7fff) * 4);
            const p1 = verts + (@as(usize, indices[@intCast(k1)] & 0x7fff) * 4);

            if (vequal(d0, p0) or vequal(d1, p0) or vequal(d0, p1) or vequal(d1, p1)) {
                continue;
            }

            if (intersect(d0, d1, p0, p1)) {
                return false;
            }
        }
    }
    return true;
}

fn inCone(i: i32, j: i32, n: i32, verts: [*]const u8, indices: []const u16) bool {
    const pi = verts + (@as(usize, indices[@intCast(i)] & 0x7fff) * 4);
    const pj = verts + (@as(usize, indices[@intCast(j)] & 0x7fff) * 4);
    const pi1 = verts + (@as(usize, indices[@intCast(next(i, n))] & 0x7fff) * 4);
    const pin1 = verts + (@as(usize, indices[@intCast(prev(i, n))] & 0x7fff) * 4);

    // If P[i] is a convex vertex [ i+1 left or on (i-1,i) ]
    if (leftOn(pin1, pi, pi1)) {
        return left(pi, pj, pin1) and left(pj, pi, pi1);
    }
    // Assume (i-1,i,i+1) not collinear
    // else P[i] is reflex
    return !(leftOn(pi, pj, pi1) and leftOn(pj, pi, pin1));
}

fn diagonal(i: i32, j: i32, n: i32, verts: [*]const u8, indices: []const u16) bool {
    return inCone(i, j, n, verts, indices) and diagonalie(i, j, n, verts, indices);
}

fn triangulate(n_in: i32, verts: [*]const u8, indices: []u16, tris: []u16) i32 {
    var n = n_in;
    var ntris: i32 = 0;
    var dst: usize = 0;

    // The last bit of the index is used to indicate if the vertex can be removed
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        const idx1 = next(i, n);
        const idx2 = next(idx1, n);
        if (diagonal(i, idx2, n, verts, indices)) {
            indices[@intCast(idx1)] |= 0x8000;
        }
    }

    while (n > 3) {
        var min_len: i32 = -1;
        var mini: i32 = -1;

        i = 0;
        while (i < n) : (i += 1) {
            const idx1 = next(i, n);
            if ((indices[@intCast(idx1)] & 0x8000) != 0) {
                const p0 = verts + (@as(usize, indices[@intCast(i)] & 0x7fff) * 4);
                const p2 = verts + (@as(usize, indices[@intCast(next(idx1, n))] & 0x7fff) * 4);

                const dx: i32 = @as(i32, p2[0]) - @as(i32, p0[0]);
                const dz: i32 = @as(i32, p2[2]) - @as(i32, p0[2]);
                const len = dx * dx + dz * dz;
                if (min_len < 0 or len < min_len) {
                    min_len = len;
                    mini = i;
                }
            }
        }

        if (mini == -1) {
            // Should not happen
            return -ntris;
        }

        i = mini;
        const idx1 = next(i, n);
        const idx2 = next(idx1, n);

        tris[dst] = indices[@intCast(i)] & 0x7fff;
        dst += 1;
        tris[dst] = indices[@intCast(idx1)] & 0x7fff;
        dst += 1;
        tris[dst] = indices[@intCast(idx2)] & 0x7fff;
        dst += 1;
        ntris += 1;

        // Removes P[i1] by copying P[i+1]...P[n-1] left one index
        n -= 1;
        var k: i32 = idx1;
        while (k < n) : (k += 1) {
            indices[@intCast(k)] = indices[@intCast(k + 1)];
        }

        var idx1_new = idx1;
        if (idx1_new >= n) idx1_new = 0;
        i = prev(idx1_new, n);
        // Update diagonal flags
        if (diagonal(prev(i, n), idx1_new, n, verts, indices)) {
            indices[@intCast(i)] |= 0x8000;
        } else {
            indices[@intCast(i)] &= 0x7fff;
        }

        if (diagonal(i, next(idx1_new, n), n, verts, indices)) {
            indices[@intCast(idx1_new)] |= 0x8000;
        } else {
            indices[@intCast(idx1_new)] &= 0x7fff;
        }
    }

    // Append the remaining triangle
    tris[dst] = indices[0] & 0x7fff;
    dst += 1;
    tris[dst] = indices[1] & 0x7fff;
    dst += 1;
    tris[dst] = indices[2] & 0x7fff;
    ntris += 1;

    return ntris;
}

// ============================================================================
// Polygon Merging Functions
// ============================================================================

fn countPolyVerts(p: []const u16) i32 {
    var i: usize = 0;
    while (i < MAX_VERTS_PER_POLY) : (i += 1) {
        if (p[i] == TILECACHE_NULL_IDX) {
            return @intCast(i);
        }
    }
    return MAX_VERTS_PER_POLY;
}

inline fn uleft(a: [*]const u16, b: [*]const u16, c: [*]const u16) bool {
    return (@as(i32, b[0]) - @as(i32, a[0])) * (@as(i32, c[2]) - @as(i32, a[2])) -
        (@as(i32, c[0]) - @as(i32, a[0])) * (@as(i32, b[2]) - @as(i32, a[2])) < 0;
}

fn getPolyMergeValue(
    pa: []u16,
    pb: []u16,
    verts: []const u16,
    ea: *i32,
    eb: *i32,
) i32 {
    const na = countPolyVerts(pa);
    const nb = countPolyVerts(pb);

    // If the merged polygon would be too big, do not merge
    if (na + nb - 2 > MAX_VERTS_PER_POLY) {
        return -1;
    }

    // Check if the polygons share an edge
    ea.* = -1;
    eb.* = -1;

    var i: i32 = 0;
    while (i < na) : (i += 1) {
        var va0 = pa[@intCast(i)];
        var va1 = pa[@intCast(@mod(i + 1, na))];
        if (va0 > va1) {
            const tmp = va0;
            va0 = va1;
            va1 = tmp;
        }
        var j: i32 = 0;
        while (j < nb) : (j += 1) {
            var vb0 = pb[@intCast(j)];
            var vb1 = pb[@intCast(@mod(j + 1, nb))];
            if (vb0 > vb1) {
                const tmp = vb0;
                vb0 = vb1;
                vb1 = tmp;
            }
            if (va0 == vb0 and va1 == vb1) {
                ea.* = i;
                eb.* = j;
                break;
            }
        }
    }

    // No common edge, cannot merge
    if (ea.* == -1 or eb.* == -1) {
        return -1;
    }

    // Check to see if the merged polygon would be convex
    var va: u16 = undefined;
    var vb: u16 = undefined;
    var vc: u16 = undefined;

    va = pa[@intCast(@mod(ea.* + na - 1, na))];
    vb = pa[@intCast(ea.*)];
    vc = pb[@intCast(@mod(eb.* + 2, nb))];
    if (!uleft(verts[@as(usize, va) * 3 ..].ptr, verts[@as(usize, vb) * 3 ..].ptr, verts[@as(usize, vc) * 3 ..].ptr)) {
        return -1;
    }

    va = pb[@intCast(@mod(eb.* + nb - 1, nb))];
    vb = pb[@intCast(eb.*)];
    vc = pa[@intCast(@mod(ea.* + 2, na))];
    if (!uleft(verts[@as(usize, va) * 3 ..].ptr, verts[@as(usize, vb) * 3 ..].ptr, verts[@as(usize, vc) * 3 ..].ptr)) {
        return -1;
    }

    va = pa[@intCast(ea.*)];
    vb = pa[@intCast(@mod(ea.* + 1, na))];

    const dx: i32 = @as(i32, verts[@as(usize, va) * 3 + 0]) - @as(i32, verts[@as(usize, vb) * 3 + 0]);
    const dy: i32 = @as(i32, verts[@as(usize, va) * 3 + 2]) - @as(i32, verts[@as(usize, vb) * 3 + 2]);

    return dx * dx + dy * dy;
}

fn mergePolys(pa: []u16, pb: []u16, ea: i32, eb: i32) void {
    var tmp: [MAX_VERTS_PER_POLY * 2]u16 = undefined;

    const na = countPolyVerts(pa);
    const nb = countPolyVerts(pb);

    // Merge polygons
    @memset(&tmp, 0xff);
    var n: usize = 0;
    // Add pa
    var i: i32 = 0;
    while (i < na - 1) : (i += 1) {
        tmp[n] = pa[@intCast(@mod(ea + 1 + i, na))];
        n += 1;
    }
    // Add pb
    i = 0;
    while (i < nb - 1) : (i += 1) {
        tmp[n] = pb[@intCast(@mod(eb + 1 + i, nb))];
        n += 1;
    }

    @memcpy(pa[0..MAX_VERTS_PER_POLY], tmp[0..MAX_VERTS_PER_POLY]);
}

// ============================================================================
// Vertex Removal Functions
// ============================================================================

inline fn pushFront(v: u16, arr: []u16, an: *i32) void {
    an.* += 1;
    var i: i32 = an.* - 1;
    while (i > 0) : (i -= 1) {
        arr[@intCast(i)] = arr[@intCast(i - 1)];
    }
    arr[0] = v;
}

inline fn pushBack(v: u16, arr: []u16, an: *i32) void {
    arr[@intCast(an.*)] = v;
    an.* += 1;
}

fn canRemoveVertex(mesh: *const TileCachePolyMesh, rem: u16) bool {
    // Count number of polygons to remove
    var num_touched_verts: i32 = 0;
    var num_remaining_edges: i32 = 0;

    var i: i32 = 0;
    while (i < mesh.npolys) : (i += 1) {
        const p = mesh.polys[@as(usize, @intCast(i)) * MAX_VERTS_PER_POLY * 2 ..];
        const nv = countPolyVerts(p[0..MAX_VERTS_PER_POLY]);
        var num_removed: i32 = 0;
        var num_verts: i32 = 0;

        var j: i32 = 0;
        while (j < nv) : (j += 1) {
            if (p[@intCast(j)] == rem) {
                num_touched_verts += 1;
                num_removed += 1;
            }
            num_verts += 1;
        }
        if (num_removed != 0) {
            num_remaining_edges += num_verts - (num_removed + 1);
        }
    }

    // There would be too few edges remaining to create a polygon
    if (num_remaining_edges <= 2) {
        return false;
    }

    // Check that there is enough memory for the test
    const max_edges = num_touched_verts * 2;
    if (max_edges > MAX_REM_EDGES) {
        return false;
    }

    // Find edges which share the removed vertex
    var edges: [MAX_REM_EDGES * 3]u16 = undefined;
    var nedges: i32 = 0;

    i = 0;
    while (i < mesh.npolys) : (i += 1) {
        const p = mesh.polys[@as(usize, @intCast(i)) * MAX_VERTS_PER_POLY * 2 ..];
        const nv = countPolyVerts(p[0..MAX_VERTS_PER_POLY]);

        // Collect edges which touches the removed vertex
        var j: i32 = 0;
        var k: i32 = nv - 1;
        while (j < nv) {
            if (p[@intCast(j)] == rem or p[@intCast(k)] == rem) {
                // Arrange edge so that a=rem
                var a: u16 = p[@intCast(j)];
                var b: u16 = p[@intCast(k)];
                if (b == rem) {
                    const tmp = a;
                    a = b;
                    b = tmp;
                }

                // Check if the edge exists
                var exists = false;
                var m: i32 = 0;
                while (m < nedges) : (m += 1) {
                    const e = edges[@as(usize, @intCast(m)) * 3 ..];
                    if (e[1] == b) {
                        // Exists, increment vertex share count
                        e[2] += 1;
                        exists = true;
                        break;
                    }
                }
                // Add new edge
                if (!exists) {
                    const e = edges[@as(usize, @intCast(nedges)) * 3 ..];
                    e[0] = a;
                    e[1] = b;
                    e[2] = 1;
                    nedges += 1;
                }
            }
            k = j;
            j += 1;
        }
    }

    // There should be no more than 2 open edges
    var num_open_edges: i32 = 0;
    i = 0;
    while (i < nedges) : (i += 1) {
        if (edges[@as(usize, @intCast(i)) * 3 + 2] < 2) {
            num_open_edges += 1;
        }
    }
    if (num_open_edges > 2) {
        return false;
    }

    return true;
}

const Status = @import("../detour.zig").Status;

fn removeVertex(
    allocator: std.mem.Allocator,
    mesh: *TileCachePolyMesh,
    rem: u16,
    max_tris: i32,
) !Status {
    var nedges: i32 = 0;
    var edges: [MAX_REM_EDGES * 3]u16 = undefined;
    var nhole: i32 = 0;
    var hole: [MAX_REM_EDGES]u16 = undefined;
    var nharea: i32 = 0;
    var harea: [MAX_REM_EDGES]u16 = undefined;

    var i: i32 = 0;
    while (i < mesh.npolys) : (i += 1) {
        const p = mesh.polys[@as(usize, @intCast(i)) * MAX_VERTS_PER_POLY * 2 ..];
        const nv = countPolyVerts(p[0..MAX_VERTS_PER_POLY]);
        var has_rem = false;
        var j: i32 = 0;
        while (j < nv) : (j += 1) {
            if (p[@intCast(j)] == rem) has_rem = true;
        }
        if (has_rem) {
            // Collect edges which does not touch the removed vertex
            j = 0;
            var k: i32 = nv - 1;
            while (j < nv) {
                if (p[@intCast(j)] != rem and p[@intCast(k)] != rem) {
                    if (nedges >= MAX_REM_EDGES) {
                        return Status{ .failure = true, .buffer_too_small = true };
                    }
                    const e = edges[@as(usize, @intCast(nedges)) * 3 ..];
                    e[0] = p[@intCast(k)];
                    e[1] = p[@intCast(j)];
                    e[2] = mesh.areas[@intCast(i)];
                    nedges += 1;
                }
                k = j;
                j += 1;
            }
            // Remove the polygon
            const p2 = mesh.polys[@as(usize, @intCast(mesh.npolys - 1)) * MAX_VERTS_PER_POLY * 2 ..];
            @memcpy(p[0..MAX_VERTS_PER_POLY], p2[0..MAX_VERTS_PER_POLY]);
            @memset(p[MAX_VERTS_PER_POLY .. MAX_VERTS_PER_POLY * 2], 0xff);
            mesh.areas[@intCast(i)] = mesh.areas[@intCast(mesh.npolys - 1)];
            mesh.npolys -= 1;
            i -= 1;
        }
    }

    // Remove vertex
    i = @intCast(rem);
    while (i < mesh.nverts - 1) : (i += 1) {
        mesh.verts[@as(usize, @intCast(i)) * 3 + 0] = mesh.verts[@as(usize, @intCast(i + 1)) * 3 + 0];
        mesh.verts[@as(usize, @intCast(i)) * 3 + 1] = mesh.verts[@as(usize, @intCast(i + 1)) * 3 + 1];
        mesh.verts[@as(usize, @intCast(i)) * 3 + 2] = mesh.verts[@as(usize, @intCast(i + 1)) * 3 + 2];
    }
    mesh.nverts -= 1;

    // Adjust indices to match the removed vertex layout
    i = 0;
    while (i < mesh.npolys) : (i += 1) {
        const p = mesh.polys[@as(usize, @intCast(i)) * MAX_VERTS_PER_POLY * 2 ..];
        const nv = countPolyVerts(p[0..MAX_VERTS_PER_POLY]);
        var j: i32 = 0;
        while (j < nv) : (j += 1) {
            if (p[@intCast(j)] > rem) {
                p[@intCast(j)] -= 1;
            }
        }
    }
    i = 0;
    while (i < nedges) : (i += 1) {
        if (edges[@as(usize, @intCast(i)) * 3 + 0] > rem) {
            edges[@as(usize, @intCast(i)) * 3 + 0] -= 1;
        }
        if (edges[@as(usize, @intCast(i)) * 3 + 1] > rem) {
            edges[@as(usize, @intCast(i)) * 3 + 1] -= 1;
        }
    }

    if (nedges == 0) {
        return Status{ .success = true };
    }

    // Start with one vertex, keep appending connected segments
    pushBack(edges[0], &hole, &nhole);
    pushBack(edges[2], &harea, &nharea);

    while (nedges != 0) {
        var match = false;

        i = 0;
        while (i < nedges) : (i += 1) {
            const ea = edges[@as(usize, @intCast(i)) * 3 + 0];
            const eb = edges[@as(usize, @intCast(i)) * 3 + 1];
            const a = edges[@as(usize, @intCast(i)) * 3 + 2];
            var add = false;
            if (hole[0] == eb) {
                // The segment matches the beginning of the hole boundary
                if (nhole >= MAX_REM_EDGES) {
                    return Status{ .failure = true, .buffer_too_small = true };
                }
                pushFront(ea, &hole, &nhole);
                pushFront(a, &harea, &nharea);
                add = true;
            } else if (hole[@intCast(nhole - 1)] == ea) {
                // The segment matches the end of the hole boundary
                if (nhole >= MAX_REM_EDGES) {
                    return Status{ .failure = true, .buffer_too_small = true };
                }
                pushBack(eb, &hole, &nhole);
                pushBack(a, &harea, &nharea);
                add = true;
            }
            if (add) {
                // The edge segment was added, remove it
                edges[@as(usize, @intCast(i)) * 3 + 0] = edges[@as(usize, @intCast(nedges - 1)) * 3 + 0];
                edges[@as(usize, @intCast(i)) * 3 + 1] = edges[@as(usize, @intCast(nedges - 1)) * 3 + 1];
                edges[@as(usize, @intCast(i)) * 3 + 2] = edges[@as(usize, @intCast(nedges - 1)) * 3 + 2];
                nedges -= 1;
                match = true;
                i -= 1;
            }
        }

        if (!match) {
            break;
        }
    }

    var tris: [MAX_REM_EDGES * 3]u16 = undefined;
    var tverts: [MAX_REM_EDGES * 4]u8 = undefined;
    var tpoly: [MAX_REM_EDGES]u16 = undefined;

    // Generate temp vertex array for triangulation
    i = 0;
    while (i < nhole) : (i += 1) {
        const pi = hole[@intCast(i)];
        tverts[@as(usize, @intCast(i)) * 4 + 0] = @intCast(mesh.verts[@as(usize, pi) * 3 + 0]);
        tverts[@as(usize, @intCast(i)) * 4 + 1] = @intCast(mesh.verts[@as(usize, pi) * 3 + 1]);
        tverts[@as(usize, @intCast(i)) * 4 + 2] = @intCast(mesh.verts[@as(usize, pi) * 3 + 2]);
        tverts[@as(usize, @intCast(i)) * 4 + 3] = 0;
        tpoly[@intCast(i)] = @intCast(i);
    }

    // Triangulate the hole
    var ntris = triangulate(nhole, &tverts, &tpoly, &tris);
    if (ntris < 0) {
        // TODO: issue warning!
        ntris = -ntris;
    }

    if (ntris > MAX_REM_EDGES) {
        return Status{ .failure = true, .buffer_too_small = true };
    }

    var polys: [MAX_REM_EDGES * MAX_VERTS_PER_POLY]u16 = undefined;
    var pareas: [MAX_REM_EDGES]u8 = undefined;

    // Build initial polygons
    var npolys: i32 = 0;
    @memset(&polys, 0xff);
    var j: i32 = 0;
    while (j < ntris) : (j += 1) {
        const t = tris[@as(usize, @intCast(j)) * 3 ..];
        if (t[0] != t[1] and t[0] != t[2] and t[1] != t[2]) {
            polys[@as(usize, @intCast(npolys)) * MAX_VERTS_PER_POLY + 0] = hole[t[0]];
            polys[@as(usize, @intCast(npolys)) * MAX_VERTS_PER_POLY + 1] = hole[t[1]];
            polys[@as(usize, @intCast(npolys)) * MAX_VERTS_PER_POLY + 2] = hole[t[2]];
            pareas[@intCast(npolys)] = @intCast(harea[t[0]]);
            npolys += 1;
        }
    }
    if (npolys == 0) {
        return Status{ .success = true };
    }

    // Merge polygons
    const max_verts_per_poly = MAX_VERTS_PER_POLY;
    if (max_verts_per_poly > 3) {
        while (true) {
            // Find best polygons to merge
            var best_merge_val: i32 = 0;
            var best_pa: i32 = 0;
            var best_pb: i32 = 0;
            var best_ea: i32 = 0;
            var best_eb: i32 = 0;

            j = 0;
            while (j < npolys - 1) : (j += 1) {
                const pj = polys[@as(usize, @intCast(j)) * MAX_VERTS_PER_POLY ..];
                var k: i32 = j + 1;
                while (k < npolys) : (k += 1) {
                    const pk = polys[@as(usize, @intCast(k)) * MAX_VERTS_PER_POLY ..];
                    var ea: i32 = undefined;
                    var eb: i32 = undefined;
                    const v = getPolyMergeValue(
                        @constCast(pj[0..MAX_VERTS_PER_POLY]),
                        @constCast(pk[0..MAX_VERTS_PER_POLY]),
                        mesh.verts[0..@as(usize, @intCast(mesh.nverts)) * 3],
                        &ea,
                        &eb,
                    );
                    if (v > best_merge_val) {
                        best_merge_val = v;
                        best_pa = j;
                        best_pb = k;
                        best_ea = ea;
                        best_eb = eb;
                    }
                }
            }

            if (best_merge_val > 0) {
                // Found best, merge
                const pa = polys[@as(usize, @intCast(best_pa)) * MAX_VERTS_PER_POLY ..];
                const pb = polys[@as(usize, @intCast(best_pb)) * MAX_VERTS_PER_POLY ..];
                mergePolys(
                    @constCast(pa[0..MAX_VERTS_PER_POLY]),
                    @constCast(pb[0..MAX_VERTS_PER_POLY]),
                    best_ea,
                    best_eb,
                );
                @memcpy(
                    pb[0..MAX_VERTS_PER_POLY],
                    polys[@as(usize, @intCast(npolys - 1)) * MAX_VERTS_PER_POLY ..][0..MAX_VERTS_PER_POLY],
                );
                pareas[@intCast(best_pb)] = pareas[@intCast(npolys - 1)];
                npolys -= 1;
            } else {
                // Could not merge any polygons, stop
                break;
            }
        }
    }

    // Store polygons
    i = 0;
    while (i < npolys) : (i += 1) {
        if (mesh.npolys >= max_tris) break;
        const p = mesh.polys[@as(usize, @intCast(mesh.npolys)) * MAX_VERTS_PER_POLY * 2 ..];
        @memset(p[0 .. MAX_VERTS_PER_POLY * 2], 0xff);
        j = 0;
        while (j < MAX_VERTS_PER_POLY) : (j += 1) {
            p[@intCast(j)] = polys[@as(usize, @intCast(i)) * MAX_VERTS_PER_POLY + @as(usize, @intCast(j))];
        }
        mesh.areas[@intCast(mesh.npolys)] = pareas[@intCast(i)];
        mesh.npolys += 1;
        if (mesh.npolys > max_tris) {
            return Status{ .failure = true, .buffer_too_small = true };
        }
    }

    _ = allocator; // Not used in this function but kept for API consistency

    return Status{ .success = true };
}

// ============================================================================
// Edge Structure and Mesh Adjacency
// ============================================================================

const Edge = struct {
    vert: [2]u16,
    poly_edge: [2]u16,
    poly: [2]u16,
};

fn buildMeshAdjacency(
    allocator: std.mem.Allocator,
    polys: []u16,
    npolys: i32,
    verts: []const u16,
    nverts: i32,
    lcset: *const TileCacheContourSet,
) !bool {
    const max_edge_count = @as(usize, @intCast(npolys)) * MAX_VERTS_PER_POLY;
    const first_edge = try allocator.alloc(u16, @as(usize, @intCast(nverts)) + max_edge_count);
    defer allocator.free(first_edge);

    const next_edge = first_edge[@intCast(nverts)..];
    var edge_count: i32 = 0;

    const edges = try allocator.alloc(Edge, @intCast(max_edge_count));
    defer allocator.free(edges);

    var i: i32 = 0;
    while (i < nverts) : (i += 1) {
        first_edge[@intCast(i)] = TILECACHE_NULL_IDX;
    }

    i = 0;
    while (i < npolys) : (i += 1) {
        const t = polys[@as(usize, @intCast(i)) * MAX_VERTS_PER_POLY * 2 ..];
        var j: i32 = 0;
        while (j < MAX_VERTS_PER_POLY) : (j += 1) {
            if (t[@intCast(j)] == TILECACHE_NULL_IDX) break;
            const v0 = t[@intCast(j)];
            const v1 = if (j + 1 >= MAX_VERTS_PER_POLY or t[@intCast(j + 1)] == TILECACHE_NULL_IDX)
                t[0]
            else
                t[@intCast(j + 1)];
            if (v0 < v1) {
                var edge = &edges[@intCast(edge_count)];
                edge.vert[0] = v0;
                edge.vert[1] = v1;
                edge.poly[0] = @intCast(i);
                edge.poly_edge[0] = @intCast(j);
                edge.poly[1] = @intCast(i);
                edge.poly_edge[1] = 0xff;
                // Insert edge
                next_edge[@intCast(edge_count)] = first_edge[v0];
                first_edge[v0] = @intCast(edge_count);
                edge_count += 1;
            }
        }
    }

    i = 0;
    while (i < npolys) : (i += 1) {
        const t = polys[@as(usize, @intCast(i)) * MAX_VERTS_PER_POLY * 2 ..];
        var j: i32 = 0;
        while (j < MAX_VERTS_PER_POLY) : (j += 1) {
            if (t[@intCast(j)] == TILECACHE_NULL_IDX) break;
            const v0 = t[@intCast(j)];
            const v1 = if (j + 1 >= MAX_VERTS_PER_POLY or t[@intCast(j + 1)] == TILECACHE_NULL_IDX)
                t[0]
            else
                t[@intCast(j + 1)];
            if (v0 > v1) {
                var found = false;
                var e = first_edge[v1];
                while (e != TILECACHE_NULL_IDX) {
                    const edge = &edges[e];
                    if (edge.vert[1] == v0 and edge.poly[0] == edge.poly[1]) {
                        edge.poly[1] = @intCast(i);
                        edge.poly_edge[1] = @intCast(j);
                        found = true;
                        break;
                    }
                    e = next_edge[e];
                }
                if (!found) {
                    // Matching edge not found, it is an open edge, add it
                    const edge = &edges[@intCast(edge_count)];
                    edge.vert[0] = v1;
                    edge.vert[1] = v0;
                    edge.poly[0] = @intCast(i);
                    edge.poly_edge[0] = @intCast(j);
                    edge.poly[1] = @intCast(i);
                    edge.poly_edge[1] = 0xff;
                    // Insert edge
                    next_edge[@intCast(edge_count)] = first_edge[v1];
                    first_edge[v1] = @intCast(edge_count);
                    edge_count += 1;
                }
            }
        }
    }

    // Mark portal edges
    i = 0;
    while (i < lcset.conts.len) : (i += 1) {
        const cont = &lcset.conts[@intCast(i)];
        if (cont.nverts < 3) {
            continue;
        }

        var j: i32 = 0;
        var k: i32 = @as(i32, @intCast(cont.nverts)) - 1;
        while (j < cont.nverts) {
            const va = cont.verts[@as(usize, @intCast(k)) * 4 ..];
            const vb = cont.verts[@as(usize, @intCast(j)) * 4 ..];
            const dir = va[3] & 0xf;
            if (dir == 0xf) {
                k = j;
                j += 1;
                continue;
            }

            if (dir == 0 or dir == 2) {
                // Find matching vertical edge
                const x = @as(u16, va[0]);
                var zmin = @as(u16, va[2]);
                var zmax = @as(u16, vb[2]);
                if (zmin > zmax) {
                    const tmp = zmin;
                    zmin = zmax;
                    zmax = tmp;
                }

                var m: i32 = 0;
                while (m < edge_count) : (m += 1) {
                    const e = &edges[@intCast(m)];
                    // Skip connected edges
                    if (e.poly[0] != e.poly[1]) {
                        continue;
                    }
                    const eva = verts[@as(usize, e.vert[0]) * 3 ..];
                    const evb = verts[@as(usize, e.vert[1]) * 3 ..];
                    if (eva[0] == x and evb[0] == x) {
                        var ezmin = @as(u16, @intCast(eva[2]));
                        var ezmax = @as(u16, @intCast(evb[2]));
                        if (ezmin > ezmax) {
                            const tmp = ezmin;
                            ezmin = ezmax;
                            ezmax = tmp;
                        }
                        if (overlapRangeExl(zmin, zmax, ezmin, ezmax)) {
                            // Reuse the other polyedge to store dir
                            e.poly_edge[1] = dir;
                        }
                    }
                }
            } else {
                // Find matching horizontal edge
                const z = @as(u16, va[2]);
                var xmin = @as(u16, va[0]);
                var xmax = @as(u16, vb[0]);
                if (xmin > xmax) {
                    const tmp = xmin;
                    xmin = xmax;
                    xmax = tmp;
                }

                var m: i32 = 0;
                while (m < edge_count) : (m += 1) {
                    const e = &edges[@intCast(m)];
                    // Skip connected edges
                    if (e.poly[0] != e.poly[1]) {
                        continue;
                    }
                    const eva = verts[@as(usize, e.vert[0]) * 3 ..];
                    const evb = verts[@as(usize, e.vert[1]) * 3 ..];
                    if (eva[2] == z and evb[2] == z) {
                        var exmin = @as(u16, @intCast(eva[0]));
                        var exmax = @as(u16, @intCast(evb[0]));
                        if (exmin > exmax) {
                            const tmp = exmin;
                            exmin = exmax;
                            exmax = tmp;
                        }
                        if (overlapRangeExl(xmin, xmax, exmin, exmax)) {
                            // Reuse the other polyedge to store dir
                            e.poly_edge[1] = dir;
                        }
                    }
                }
            }

            k = j;
            j += 1;
        }
    }

    // Store adjacency
    i = 0;
    while (i < edge_count) : (i += 1) {
        const e = &edges[@intCast(i)];
        if (e.poly[0] != e.poly[1]) {
            const p0 = polys[@as(usize, e.poly[0]) * MAX_VERTS_PER_POLY * 2 ..];
            const p1 = polys[@as(usize, e.poly[1]) * MAX_VERTS_PER_POLY * 2 ..];
            p0[MAX_VERTS_PER_POLY + e.poly_edge[0]] = e.poly[1];
            p1[MAX_VERTS_PER_POLY + e.poly_edge[1]] = e.poly[0];
        } else if (e.poly_edge[1] != 0xff) {
            const p0 = polys[@as(usize, e.poly[0]) * MAX_VERTS_PER_POLY * 2 ..];
            p0[MAX_VERTS_PER_POLY + e.poly_edge[0]] = 0x8000 | @as(u16, e.poly_edge[1]);
        }
    }

    return true;
}

// ============================================================================
// Main Build Function
// ============================================================================

pub fn buildTileCachePolyMesh(
    allocator: std.mem.Allocator,
    lcset: *const TileCacheContourSet,
    mesh: *TileCachePolyMesh,
) !Status {
    var max_vertices: i32 = 0;
    var max_tris: i32 = 0;
    var max_verts_per_cont: i32 = 0;

    for (lcset.conts) |*cont| {
        // Skip null contours
        if (cont.nverts < 3) continue;
        max_vertices += @intCast(cont.nverts);
        max_tris += @as(i32, @intCast(cont.nverts)) - 2;
        max_verts_per_cont = @max(max_verts_per_cont, @as(i32, @intCast(cont.nverts)));
    }

    mesh.nvp = MAX_VERTS_PER_POLY;

    const vflags = try allocator.alloc(u8, @intCast(max_vertices));
    defer allocator.free(vflags);
    @memset(vflags, 0);

    mesh.verts = try allocator.alloc(u16, @as(usize, @intCast(max_vertices)) * 3);
    mesh.polys = try allocator.alloc(u16, @as(usize, @intCast(max_tris)) * MAX_VERTS_PER_POLY * 2);
    mesh.areas = try allocator.alloc(u8, @intCast(max_tris));
    mesh.flags = try allocator.alloc(u16, @intCast(max_tris));

    // Just allocate and clean the mesh flags array
    @memset(mesh.flags, 0);

    mesh.nverts = 0;
    mesh.npolys = 0;

    @memset(mesh.verts, 0);
    @memset(mesh.polys, 0xff);
    @memset(mesh.areas, 0);

    var first_vert: [VERTEX_BUCKET_COUNT2]u16 = undefined;
    for (&first_vert) |*v| {
        v.* = TILECACHE_NULL_IDX;
    }

    const next_vert = try allocator.alloc(u16, @intCast(max_vertices));
    defer allocator.free(next_vert);
    @memset(next_vert, 0);

    const indices = try allocator.alloc(u16, @intCast(max_verts_per_cont));
    defer allocator.free(indices);

    const tris = try allocator.alloc(u16, @as(usize, @intCast(max_verts_per_cont)) * 3);
    defer allocator.free(tris);

    const polys = try allocator.alloc(u16, @as(usize, @intCast(max_verts_per_cont)) * MAX_VERTS_PER_POLY);
    defer allocator.free(polys);

    var nverts_i32: i32 = @intCast(mesh.nverts);

    for (lcset.conts) |*cont| {
        // Skip null contours
        if (cont.nverts < 3) {
            continue;
        }

        // Triangulate contour
        var j: usize = 0;
        while (j < cont.nverts) : (j += 1) {
            indices[j] = @intCast(j);
        }

        var ntris = triangulate(@intCast(cont.nverts), cont.verts.ptr, indices, tris);
        if (ntris <= 0) {
            // TODO: issue warning!
            ntris = -ntris;
        }

        // Add and merge vertices
        j = 0;
        while (j < cont.nverts) : (j += 1) {
            const v = cont.verts[j * 4 ..];
            indices[j] = addVertex(
                @as(u16, v[0]),
                @as(u16, v[1]),
                @as(u16, v[2]),
                mesh.verts,
                &first_vert,
                next_vert,
                &nverts_i32,
            );
            if ((v[3] & 0x80) != 0) {
                // This vertex should be removed
                vflags[indices[j]] = 1;
            }
        }

        // Build initial polygons
        var npolys: i32 = 0;
        @memset(polys, 0xff);
        j = 0;
        while (j < ntris) : (j += 1) {
            const t = tris[@as(usize, @intCast(j)) * 3 ..];
            if (t[0] != t[1] and t[0] != t[2] and t[1] != t[2]) {
                polys[@as(usize, @intCast(npolys)) * MAX_VERTS_PER_POLY + 0] = indices[t[0]];
                polys[@as(usize, @intCast(npolys)) * MAX_VERTS_PER_POLY + 1] = indices[t[1]];
                polys[@as(usize, @intCast(npolys)) * MAX_VERTS_PER_POLY + 2] = indices[t[2]];
                npolys += 1;
            }
        }
        if (npolys == 0) {
            continue;
        }

        // Merge polygons
        const max_verts_per_poly = MAX_VERTS_PER_POLY;
        if (max_verts_per_poly > 3) {
            while (true) {
                // Find best polygons to merge
                var best_merge_val: i32 = 0;
                var best_pa: i32 = 0;
                var best_pb: i32 = 0;
                var best_ea: i32 = 0;
                var best_eb: i32 = 0;

                var j2: i32 = 0;
                while (j2 < npolys - 1) : (j2 += 1) {
                    const pj = polys[@as(usize, @intCast(j2)) * MAX_VERTS_PER_POLY ..];
                    var k: i32 = j2 + 1;
                    while (k < npolys) : (k += 1) {
                        const pk = polys[@as(usize, @intCast(k)) * MAX_VERTS_PER_POLY ..];
                        var ea: i32 = undefined;
                        var eb: i32 = undefined;
                        const v = getPolyMergeValue(
                            @constCast(pj[0..MAX_VERTS_PER_POLY]),
                            @constCast(pk[0..MAX_VERTS_PER_POLY]),
                            mesh.verts[0..@as(usize, @intCast(mesh.nverts)) * 3],
                            &ea,
                            &eb,
                        );
                        if (v > best_merge_val) {
                            best_merge_val = v;
                            best_pa = j2;
                            best_pb = k;
                            best_ea = ea;
                            best_eb = eb;
                        }
                    }
                }

                if (best_merge_val > 0) {
                    // Found best, merge
                    const pa = polys[@as(usize, @intCast(best_pa)) * MAX_VERTS_PER_POLY ..];
                    const pb = polys[@as(usize, @intCast(best_pb)) * MAX_VERTS_PER_POLY ..];
                    mergePolys(
                        @constCast(pa[0..MAX_VERTS_PER_POLY]),
                        @constCast(pb[0..MAX_VERTS_PER_POLY]),
                        best_ea,
                        best_eb,
                    );
                    @memcpy(
                        pb[0..MAX_VERTS_PER_POLY],
                        polys[@as(usize, @intCast(npolys - 1)) * MAX_VERTS_PER_POLY ..][0..MAX_VERTS_PER_POLY],
                    );
                    npolys -= 1;
                } else {
                    // Could not merge any polygons, stop
                    break;
                }
            }
        }

        // Store polygons
        j = 0;
        while (j < npolys) : (j += 1) {
            const p = mesh.polys[@as(usize, @intCast(mesh.npolys)) * MAX_VERTS_PER_POLY * 2 ..];
            const q = polys[@as(usize, @intCast(j)) * MAX_VERTS_PER_POLY ..];
            var k: usize = 0;
            while (k < MAX_VERTS_PER_POLY) : (k += 1) {
                p[k] = q[k];
            }
            mesh.areas[@intCast(mesh.npolys)] = cont.area;
            mesh.npolys += 1;
            if (mesh.npolys > max_tris) {
                return Status{ .failure = true, .buffer_too_small = true };
            }
        }
    }

    mesh.nverts = @intCast(nverts_i32);

    // Remove edge vertices
    var i: i32 = 0;
    while (i < mesh.nverts) : (i += 1) {
        if (vflags[@intCast(i)] != 0) {
            if (!canRemoveVertex(mesh, @intCast(i))) {
                continue;
            }
            const status = try removeVertex(allocator, mesh, @intCast(i), max_tris);
            if (status.isFailure()) {
                return status;
            }
            // Remove vertex
            // Note: mesh.nverts is already decremented inside removeVertex()!
            var j: i32 = i;
            while (j < mesh.nverts) : (j += 1) {
                vflags[@intCast(j)] = vflags[@intCast(j + 1)];
            }
            i -= 1;
        }
    }

    // Calculate adjacency
    if (!try buildMeshAdjacency(allocator, mesh.polys, @intCast(mesh.npolys), mesh.verts, @intCast(mesh.nverts), lcset)) {
        return Status{ .failure = true, .out_of_memory = true };
    }

    return Status{ .success = true };
}
