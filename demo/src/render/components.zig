//! Connected components of the navmesh: each polygon gets a 1-based component id
//! via flood-fill over poly links (generalises tool_prune.floodNavmesh). Feeds
//! the `component` colour scheme to paint connectivity islands. Computed on
//! demand from the navmesh alone — no baked data. NOTE: O(polys+links) per call;
//! callers recompute per draw while the scheme is active (cache later if needed).

const std = @import("std");
const recast = @import("recast-nav");
const dt = recast.detour;

pub const Components = struct {
    alloc: std.mem.Allocator,
    tile_comp: []?[]u16 = &.{}, // per tile: id per poly (0 = unassigned), or null for empty tile
    count: u16 = 0,

    pub fn deinit(self: *Components) void {
        for (self.tile_comp) |maybe| {
            if (maybe) |s| self.alloc.free(s);
        }
        if (self.tile_comp.len > 0) self.alloc.free(self.tile_comp);
        self.tile_comp = &.{};
    }

    /// Component id for a poly slot (1-based; 0 = none/empty). No bounds check.
    pub fn getByIndex(self: *const Components, tile_idx: usize, poly_idx: usize) u16 {
        return if (self.tile_comp[tile_idx]) |s| s[poly_idx] else 0;
    }

    /// Component id for a poly REF (decodes ref -> tile/poly, bounds-checked).
    /// Returns null for ref==0 or out-of-range refs. Used by diagnostics to test
    /// topological (neutral) connectivity: same id => same flood-fill island.
    /// Идентификатор компоненты по REF полигона (с декодированием и проверкой границ).
    pub fn componentForRef(self: *const Components, nav: *const dt.NavMesh, ref: dt.PolyRef) ?u16 {
        if (ref == 0) return null;
        const d = nav.decodePolyId(ref);
        if (d.tile >= self.tile_comp.len) return null;
        const slot = self.tile_comp[d.tile] orelse return null;
        if (d.poly >= slot.len) return null;
        return slot[d.poly];
    }
};

/// Flood-fill the whole navmesh into connected components.
pub fn compute(nav: *const dt.NavMesh, alloc: std.mem.Allocator) !Components {
    var comps = Components{ .alloc = alloc };
    const num_tiles: usize = @intCast(nav.max_tiles);
    if (num_tiles == 0) return comps;

    comps.tile_comp = try alloc.alloc(?[]u16, num_tiles);
    for (comps.tile_comp) |*slot| slot.* = null;
    errdefer comps.deinit();

    for (0..num_tiles) |i| {
        const tile = &nav.tiles[i];
        const header = tile.header orelse continue;
        const pc: usize = @intCast(header.poly_count);
        const s = try alloc.alloc(u16, pc);
        @memset(s, 0);
        comps.tile_comp[i] = s;
    }

    var open = std.array_list.Managed(dt.PolyRef).init(alloc);
    defer open.deinit();

    for (0..num_tiles) |i| {
        const tile = &nav.tiles[i];
        const header = tile.header orelse continue;
        const base = nav.getPolyRefBase(tile);
        const pc: usize = @intCast(header.poly_count);
        for (0..pc) |j| {
            const ref = base | @as(dt.PolyRef, @intCast(j));
            const d0 = nav.decodePolyId(ref);
            if (comps.tile_comp[d0.tile].?[d0.poly] != 0) continue;

            comps.count += 1;
            const cid = comps.count;
            comps.tile_comp[d0.tile].?[d0.poly] = cid;

            open.clearRetainingCapacity();
            try open.append(ref);
            while (open.items.len > 0) {
                const r = open.pop().?;
                var t2: ?*const dt.MeshTile = null;
                var p2: ?*const dt.Poly = null;
                nav.getTileAndPolyByRefUnsafe(r, &t2, &p2);
                const tt = t2.?;
                const pp = p2.?;
                var li: u32 = pp.first_link;
                while (li != dt.NULL_LINK) : (li = tt.links[li].next) {
                    const nref = tt.links[li].ref;
                    if (nref == 0) continue;
                    const dn = nav.decodePolyId(nref);
                    if (comps.tile_comp[dn.tile].?[dn.poly] != 0) continue;
                    comps.tile_comp[dn.tile].?[dn.poly] = cid;
                    try open.append(nref);
                }
            }
        }
    }
    return comps;
}
