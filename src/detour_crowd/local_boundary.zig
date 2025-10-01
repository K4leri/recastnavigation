const std = @import("std");
const detour = @import("../detour.zig");
const query_mod = @import("../detour/query.zig");
const math = @import("../math.zig");

const NavMeshQuery = detour.NavMeshQuery;
const QueryFilter = detour.QueryFilter;
const PolyRef = detour.PolyRef;

/// Represents the local boundary of an agent
/// Used for collision avoidance and movement constraints
pub const LocalBoundary = struct {
    const MAX_LOCAL_SEGS = 8;
    const MAX_LOCAL_POLYS = 16;

    const Segment = struct {
        s: [6]f32, // Segment start/end (2 points * 3 coords)
        d: f32, // Distance for pruning
    };

    center: [3]f32,
    segs: [MAX_LOCAL_SEGS]Segment,
    nsegs: usize,
    polys: [MAX_LOCAL_POLYS]PolyRef,
    npolys: usize,

    const Self = @This();

    /// Initialize a local boundary
    pub fn init() Self {
        return Self{
            .center = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) },
            .segs = [_]Segment{.{ .s = [_]f32{0} ** 6, .d = 0 }} ** MAX_LOCAL_SEGS,
            .nsegs = 0,
            .polys = [_]PolyRef{0} ** MAX_LOCAL_POLYS,
            .npolys = 0,
        };
    }

    /// Reset the local boundary
    pub fn reset(self: *Self) void {
        self.center = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
        self.npolys = 0;
        self.nsegs = 0;
    }

    /// Get the center position
    pub fn getCenter(self: *const Self) *const [3]f32 {
        return &self.center;
    }

    /// Get the number of segments
    pub fn getSegmentCount(self: *const Self) usize {
        return self.nsegs;
    }

    /// Get a segment by index
    pub fn getSegment(self: *const Self, i: usize) *const [6]f32 {
        return &self.segs[i].s;
    }

    /// Add a segment sorted by distance
    fn addSegment(self: *Self, dist: f32, s: *const [6]f32) void {
        var seg: ?*Segment = null;

        if (self.nsegs == 0) {
            // First, trivial accept
            seg = &self.segs[0];
        } else if (dist >= self.segs[self.nsegs - 1].d) {
            // Further than the last segment
            if (self.nsegs >= MAX_LOCAL_SEGS) {
                return;
            }
            // Last, trivial accept
            seg = &self.segs[self.nsegs];
        } else {
            // Insert in between
            var i: usize = 0;
            while (i < self.nsegs) : (i += 1) {
                if (dist <= self.segs[i].d) {
                    break;
                }
            }
            const tgt = i + 1;
            const n = @min(self.nsegs - i, MAX_LOCAL_SEGS - tgt);
            if (n > 0) {
                std.mem.copyBackwards(Segment, self.segs[tgt .. tgt + n], self.segs[i .. i + n]);
            }
            seg = &self.segs[i];
        }

        if (seg) |segment| {
            segment.d = dist;
            @memcpy(&segment.s, s);
        }

        if (self.nsegs < MAX_LOCAL_SEGS) {
            self.nsegs += 1;
        }
    }

    /// Update the local boundary
    pub fn update(
        self: *Self,
        ref: PolyRef,
        pos: *const [3]f32,
        collision_query_range: f32,
        navquery: *const NavMeshQuery,
        filter: *const QueryFilter,
        allocator: std.mem.Allocator,
    ) !void {
        _ = allocator;

        if (ref == 0) {
            self.center = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
            self.nsegs = 0;
            self.npolys = 0;
            return;
        }

        math.vcopy(&self.center, pos);

        // First query non-overlapping polygons
        var npolys: usize = 0;
        _ = try navquery.findLocalNeighbourhood(
            ref,
            pos,
            collision_query_range,
            filter,
            &self.polys,
            null,
            &npolys,
        );
        self.npolys = npolys;

        // Secondly, store all polygon edges
        self.nsegs = 0;

        const MAX_SEGS_PER_POLY = 20; // DT_VERTS_PER_POLYGON is typically 6, * 3 for safety
        var segs: [MAX_SEGS_PER_POLY * 6]f32 = undefined;
        var nsegs: usize = 0;

        for (0..self.npolys) |j| {
            _ = try query_mod.getPolyWallSegments(
                navquery,
                self.polys[j],
                filter,
                &segs,
                null,
                &nsegs,
                MAX_SEGS_PER_POLY,
            );

            for (0..nsegs) |k| {
                const seg_start: [3]f32 = .{
                    segs[k * 6 + 0],
                    segs[k * 6 + 1],
                    segs[k * 6 + 2],
                };
                const seg_end: [3]f32 = .{
                    segs[k * 6 + 3],
                    segs[k * 6 + 4],
                    segs[k * 6 + 5],
                };
                var tseg: f32 = undefined;
                const dist_sqr = math.distancePtSegSqr2D(pos, &seg_start, &seg_end, &tseg);
                if (dist_sqr > collision_query_range * collision_query_range) {
                    continue;
                }
                const seg_full: [6]f32 = .{
                    segs[k * 6 + 0],
                    segs[k * 6 + 1],
                    segs[k * 6 + 2],
                    segs[k * 6 + 3],
                    segs[k * 6 + 4],
                    segs[k * 6 + 5],
                };
                self.addSegment(dist_sqr, &seg_full);
            }
        }
    }

    /// Check if the local boundary is valid
    pub fn isValid(self: *const Self, navquery: *const NavMeshQuery, filter: *const QueryFilter) bool {
        if (self.npolys == 0) {
            return false;
        }

        // Check that all polygons still pass query filter
        for (0..self.npolys) |i| {
            if (!navquery.isValidPolyRef(self.polys[i], filter)) {
                return false;
            }
        }

        return true;
    }
};

test "LocalBoundary basic" {
    var boundary = LocalBoundary.init();
    boundary.reset();

    try std.testing.expectEqual(@as(usize, 0), boundary.getSegmentCount());
}
