const std = @import("std");
const math = @import("../math.zig");
const Vec3 = math.Vec3;

/// Contour representing region outline
pub const Contour = struct {
    verts: []i32, // Simplified contour vertices [4 * nverts]
    nverts: i32, // Number of simplified vertices
    rverts: []i32, // Raw contour vertices [4 * nrverts]
    nrverts: i32, // Number of raw vertices
    reg: u16, // Region ID
    area: u8, // Area ID
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .verts = &[_]i32{},
            .nverts = 0,
            .rverts = &[_]i32{},
            .nrverts = 0,
            .reg = 0,
            .area = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.verts.len > 0) self.allocator.free(self.verts);
        if (self.rverts.len > 0) self.allocator.free(self.rverts);
        self.* = undefined;
    }
};

/// Set of contours
pub const ContourSet = struct {
    conts: []Contour,
    nconts: i32,
    bmin: Vec3,
    bmax: Vec3,
    cs: f32,
    ch: f32,
    width: i32,
    height: i32,
    border_size: i32,
    max_error: f32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .conts = &[_]Contour{},
            .nconts = 0,
            .bmin = Vec3.zero(),
            .bmax = Vec3.zero(),
            .cs = 0,
            .ch = 0,
            .width = 0,
            .height = 0,
            .border_size = 0,
            .max_error = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.conts) |*cont| {
            cont.deinit();
        }
        if (self.conts.len > 0) self.allocator.free(self.conts);
        self.* = undefined;
    }
};

/// Polygon mesh suitable for navigation mesh building
pub const PolyMesh = struct {
    verts: []u16, // Vertices [(x,y,z) * nverts]
    polys: []u16, // Polygon and neighbor data [maxpolys * 2 * nvp]
    regs: []u16, // Region IDs [maxpolys]
    flags: []u16, // User flags [maxpolys]
    areas: []u8, // Area IDs [maxpolys]
    nverts: i32, // Number of vertices
    npolys: i32, // Number of polygons
    maxpolys: i32, // Allocated polygon count
    nvp: i32, // Max vertices per polygon
    bmin: Vec3,
    bmax: Vec3,
    cs: f32,
    ch: f32,
    border_size: i32,
    max_edge_error: f32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .verts = &[_]u16{},
            .polys = &[_]u16{},
            .regs = &[_]u16{},
            .flags = &[_]u16{},
            .areas = &[_]u8{},
            .nverts = 0,
            .npolys = 0,
            .maxpolys = 0,
            .nvp = 0,
            .bmin = Vec3.zero(),
            .bmax = Vec3.zero(),
            .cs = 0,
            .ch = 0,
            .border_size = 0,
            .max_edge_error = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.verts.len > 0) self.allocator.free(self.verts);
        if (self.polys.len > 0) self.allocator.free(self.polys);
        if (self.regs.len > 0) self.allocator.free(self.regs);
        if (self.flags.len > 0) self.allocator.free(self.flags);
        if (self.areas.len > 0) self.allocator.free(self.areas);
        self.* = undefined;
    }
};

/// Detail mesh for polygon mesh
pub const PolyMeshDetail = struct {
    meshes: []u32, // Sub-mesh data [4 * nmeshes]
    verts: []f32, // Vertices [3 * nverts]
    tris: []u8, // Triangles [4 * ntris]
    nmeshes: i32,
    nverts: i32,
    ntris: i32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .meshes = &[_]u32{},
            .verts = &[_]f32{},
            .tris = &[_]u8{},
            .nmeshes = 0,
            .nverts = 0,
            .ntris = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.meshes.len > 0) self.allocator.free(self.meshes);
        if (self.verts.len > 0) self.allocator.free(self.verts);
        if (self.tris.len > 0) self.allocator.free(self.tris);
        self.* = undefined;
    }
};

/// Heightfield layer
pub const HeightfieldLayer = struct {
    bmin: Vec3,
    bmax: Vec3,
    cs: f32,
    ch: f32,
    width: i32,
    height: i32,
    minx: i32,
    maxx: i32,
    miny: i32,
    maxy: i32,
    hmin: i32,
    hmax: i32,
    heights: []u8,
    areas: []u8,
    cons: []u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .bmin = Vec3.zero(),
            .bmax = Vec3.zero(),
            .cs = 0,
            .ch = 0,
            .width = 0,
            .height = 0,
            .minx = 0,
            .maxx = 0,
            .miny = 0,
            .maxy = 0,
            .hmin = 0,
            .hmax = 0,
            .heights = &[_]u8{},
            .areas = &[_]u8{},
            .cons = &[_]u8{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.heights.len > 0) self.allocator.free(self.heights);
        if (self.areas.len > 0) self.allocator.free(self.areas);
        if (self.cons.len > 0) self.allocator.free(self.cons);
        self.* = undefined;
    }
};

/// Heightfield layer set
pub const HeightfieldLayerSet = struct {
    layers: []HeightfieldLayer,
    nlayers: i32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .layers = &[_]HeightfieldLayer{},
            .nlayers = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.layers) |*layer| {
            layer.deinit();
        }
        if (self.layers.len > 0) self.allocator.free(self.layers);
        self.* = undefined;
    }
};
