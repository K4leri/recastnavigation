//! EditOp — a single reversible scene edit (cluster F, feature F1 core).
//!
//! Each variant captures ALL data needed to both redo (`apply`) and undo
//! (`revert`) the mutation against a live `*InputGeom`:
//!
//!   - add_volume     : the full ConvexVolume that was appended (id/mode/band/
//!                      verts) — redo re-appends a copy, undo removes the last.
//!   - delete_volume  : the full ConvexVolume that was removed PLUS its former
//!                      index — undo re-inserts the captured copy at that index,
//!                      restoring id/mode/band/verts byte-for-byte; redo deletes
//!                      it again.
//!   - add_offmesh    : the 6 off-mesh fields (verts[6]/rad/dir/area/flags/id) of
//!                      the connection that was appended — redo re-appends, undo
//!                      removes the last.
//!   - delete_offmesh : the 6 off-mesh fields PLUS the former index — undo
//!                      re-inserts at that index, redo deletes it again.
//!
//! Because `ConvexVolume` is a value type (its `verts` is a fixed [12*3]f32
//! array, not a slice) and the off-mesh capture is all scalars + a [6]f32, an
//! EditOp owns NO heap memory — copies are by value. `deinit` exists so the
//! UndoStack can call it uniformly and so a future variant that DOES own heap
//! data has a hook to free it.

const std = @import("std");
const ig = @import("../input_geom.zig");
const InputGeom = ig.InputGeom;
const ConvexVolume = ig.ConvexVolume;
const area_types = @import("../area_types.zig");
const poly_flags = @import("../poly_flags.zig");
const AreaType = area_types.AreaType;
const Flag = poly_flags.Flag;

/// After any area-type / poly-flag mutation (apply or revert) the registries that
/// feed baked tile data + the live query filters have changed: signal both a
/// navmesh rebuild and a cost re-apply, mirroring how the live editors do it.
fn markAreaDirty() void {
    area_types.rebuild_needed = true;
    area_types.costs_dirty = true;
}

/// Locate the array index of the convex volume whose `.id == id`, or null if no
/// volume currently carries that id (e.g. it was deleted). Used by the id-keyed
/// `edit_volume` op so it hits the right object even after the list reordered.
fn volumeIndexById(geom: *const InputGeom, id: u32) ?usize {
    for (geom.volumes.items, 0..) |*vol, i| {
        if (vol.id == id) return i;
    }
    return null;
}

/// Locate the array index of the off-mesh connection whose `off_id == id`, or
/// null if none currently carries that id. Used by the id-keyed `edit_offmesh`.
fn offmeshIndexById(geom: *const InputGeom, id: u32) ?usize {
    for (geom.off_id.items, 0..) |oid, i| {
        if (oid == id) return i;
    }
    return null;
}

/// Overwrite the 6 mutable fields of the off-mesh at `idx` from `data` (the
/// stable `.id` key in `off_id` is intentionally left untouched).
fn writeOffmesh(geom: *InputGeom, idx: usize, data: OffMeshData) void {
    @memcpy(geom.off_verts.items[idx * 6 ..][0..6], &data.verts);
    geom.off_rad.items[idx] = data.rad;
    geom.off_dir.items[idx] = data.dir;
    geom.off_area.items[idx] = data.area;
    geom.off_flags.items[idx] = data.flags;
}

/// Reversible capture of one off-mesh connection (all 6 parallel-array fields).
pub const OffMeshData = struct {
    verts: [6]f32,
    rad: f32,
    dir: u8,
    area: u8,
    flags: u16,
    id: u32,

    /// Snapshot the connection currently stored at `idx` in `geom`.
    pub fn capture(geom: *const InputGeom, idx: usize) OffMeshData {
        return .{
            .verts = geom.off_verts.items[idx * 6 ..][0..6].*,
            .rad = geom.off_rad.items[idx],
            .dir = geom.off_dir.items[idx],
            .area = geom.off_area.items[idx],
            .flags = geom.off_flags.items[idx],
            .id = geom.off_id.items[idx],
        };
    }
};

pub const EditOp = union(enum) {
    add_volume: ConvexVolume,
    delete_volume: struct { index: usize, vol: ConvexVolume },
    add_offmesh: OffMeshData,
    delete_offmesh: struct { index: usize, data: OffMeshData },

    // --- In-place edits (id-keyed) --------------------------------------------
    // These mutate an EXISTING object in place. They are keyed by STABLE id (not
    // array index) so they survive the list reordering that undo/redo of OTHER
    // edits performs between record and undo. Both serve feature F3 group-move and
    // the future F5 property edit. If the target id no longer exists (it was
    // deleted), apply/revert are silent no-ops — never a crash.
    /// A volume (found by .id) was overwritten: apply -> after, revert -> before.
    edit_volume: struct { id: u32, before: ConvexVolume, after: ConvexVolume },
    /// An off-mesh (found by off_id) had its 6 fields overwritten. The .id field
    /// is the key and never changes; apply -> after, revert -> before.
    edit_offmesh: struct { id: u32, before: OffMeshData, after: OffMeshData },

    // --- Scene-markup registry edits (area types + poly flags) ----------------
    // These operate on the MODULE-GLOBAL registries (area_types / poly_flags),
    // not on `geom` — the `geom` param to apply/revert is ignored for them. Each
    // captures the affected slot's value by COPY: AreaType / Flag hold fixed-size
    // name_buf arrays, so the copy is self-contained and owns no heap.
    /// A NEW area type was created at slot `id`. apply re-creates it, revert removes it.
    area_add: struct { id: usize, type: AreaType },
    /// An existing area type at slot `id` was edited. apply -> after, revert -> before.
    area_edit: struct { id: usize, before: AreaType, after: AreaType },
    /// An area type at slot `id` was removed. apply removes it, revert restores it.
    area_remove: struct { id: usize, type: AreaType },
    /// A NEW poly flag was created at bit `bit_index`. apply re-creates, revert removes.
    flag_add: struct { bit_index: usize, flag: Flag },
    /// A poly flag at bit `bit_index` was removed. apply removes, revert restores it.
    flag_remove: struct { bit_index: usize, flag: Flag },

    // --- Composite (group) edit -----------------------------------------------
    /// A group of sub-edits recorded / undone / redone as ONE unit (feature F3).
    /// Owns its `ops` slice on the heap; `apply` runs them FORWARD, `revert` runs
    /// them in REVERSE (so paired inserts/deletes unwind correctly — e.g. a
    /// group-delete of several indices must re-insert in reverse). `deinit`
    /// deinits every sub-op then frees the slice. Single ownership: the op lives
    /// in exactly one UndoStack ring slot at a time (moves are by value copy),
    /// so the slice is freed exactly once — no double-free across ring moves.
    composite: struct { ops: []EditOp, alloc: std.mem.Allocator },

    /// Redo the action (re-perform the original mutation).
    pub fn apply(self: EditOp, geom: *InputGeom) void {
        switch (self) {
            .add_volume => |vol| {
                // Re-append the exact captured volume (id/mode/band preserved).
                geom.insertConvexVolume(geom.volumes.items.len, vol) catch {};
            },
            .delete_volume => |d| {
                geom.deleteConvexVolume(d.index);
            },
            .add_offmesh => |d| {
                geom.insertOffMeshConnection(geom.offMeshCount(), d.verts, d.rad, d.dir, d.area, d.flags, d.id) catch {};
            },
            .delete_offmesh => |d| {
                geom.deleteOffMeshConnection(d.index);
            },
            .edit_volume => |e| {
                // Overwrite the (id-keyed) volume with `after`; missing -> no-op.
                if (volumeIndexById(geom, e.id)) |i| geom.volumes.items[i] = e.after;
            },
            .edit_offmesh => |e| {
                // Overwrite the (id-keyed) connection's 6 fields with `after`.
                if (offmeshIndexById(geom, e.id)) |i| writeOffmesh(geom, i, e.after);
            },
            .area_add => |a| {
                area_types.restoreType(a.id, a.type);
                markAreaDirty();
            },
            .area_edit => |a| {
                area_types.restoreType(a.id, a.after);
                markAreaDirty();
            },
            .area_remove => |a| {
                area_types.removeType(a.id);
                markAreaDirty();
            },
            .flag_add => |f| {
                poly_flags.restoreFlag(f.bit_index, f.flag.name(), f.flag.builtin);
                // Flag DEFINITIONS do not touch baked tile data — no rebuild needed.
            },
            .flag_remove => |f| {
                poly_flags.removeFlag(f.bit_index);
                // Flag DEFINITIONS do not touch baked tile data — no rebuild needed.
            },
            .composite => |c| {
                // Redo the group: replay sub-ops in FORWARD order.
                for (c.ops) |op| op.apply(geom);
            },
        }
    }

    /// Undo the action (reverse the original mutation).
    pub fn revert(self: EditOp, geom: *InputGeom) void {
        switch (self) {
            .add_volume => {
                // The add appended to the end — remove the last volume.
                if (geom.volumes.items.len > 0)
                    geom.deleteConvexVolume(geom.volumes.items.len - 1);
            },
            .delete_volume => |d| {
                geom.insertConvexVolume(d.index, d.vol) catch {};
            },
            .add_offmesh => {
                if (geom.offMeshCount() > 0)
                    geom.deleteOffMeshConnection(geom.offMeshCount() - 1);
            },
            .delete_offmesh => |d| {
                geom.insertOffMeshConnection(d.index, d.data.verts, d.data.rad, d.data.dir, d.data.area, d.data.flags, d.data.id) catch {};
            },
            .edit_volume => |e| {
                // Restore the (id-keyed) volume to `before`; missing -> no-op.
                if (volumeIndexById(geom, e.id)) |i| geom.volumes.items[i] = e.before;
            },
            .edit_offmesh => |e| {
                // Restore the (id-keyed) connection's 6 fields to `before`.
                if (offmeshIndexById(geom, e.id)) |i| writeOffmesh(geom, i, e.before);
            },
            .area_add => |a| {
                area_types.removeType(a.id);
                markAreaDirty();
            },
            .area_edit => |a| {
                area_types.restoreType(a.id, a.before);
                markAreaDirty();
            },
            .area_remove => |a| {
                area_types.restoreType(a.id, a.type);
                markAreaDirty();
            },
            .flag_add => |f| {
                poly_flags.removeFlag(f.bit_index);
                // Flag DEFINITIONS do not touch baked tile data — no rebuild needed.
            },
            .flag_remove => |f| {
                poly_flags.restoreFlag(f.bit_index, f.flag.name(), f.flag.builtin);
                // Flag DEFINITIONS do not touch baked tile data — no rebuild needed.
            },
            .composite => |c| {
                // Undo the group: revert sub-ops in REVERSE order so paired
                // inserts/deletes unwind in the inverse sequence they applied.
                var i: usize = c.ops.len;
                while (i > 0) {
                    i -= 1;
                    c.ops[i].revert(geom);
                }
            },
        }
    }

    /// Free any heap-owned data. All POD variants are a no-op (value copies);
    /// only `composite` owns heap (its `ops` slice), so it deinits each sub-op
    /// then frees the slice. Switch on `self.*` since `self` is a pointer.
    /// Called exactly once per op by the UndoStack (on evict/clear/drop) and the
    /// op exists in exactly one ring slot, so the slice is freed once — no leak,
    /// no double-free.
    pub fn deinit(self: *EditOp) void {
        switch (self.*) {
            .composite => |*c| {
                for (c.ops) |*op| op.deinit();
                c.alloc.free(c.ops);
            },
            else => {},
        }
    }

    /// Short human label for the panel tooltip ("Undo: Add Volume").
    pub fn name(self: EditOp) []const u8 {
        return switch (self) {
            .add_volume => "Add Volume",
            .delete_volume => "Delete Volume",
            .add_offmesh => "Add Off-Mesh Link",
            .delete_offmesh => "Delete Off-Mesh Link",
            .edit_volume => "Move/Edit Volume",
            .edit_offmesh => "Move/Edit Off-Mesh",
            .area_add => "Add Area Type",
            .area_edit => "Edit Area Type",
            .area_remove => "Remove Area Type",
            .flag_add => "Add Poly Flag",
            .flag_remove => "Remove Poly Flag",
            .composite => "Group Edit",
        };
    }
};

/// Wrap an already-owned heap slice of sub-ops into a composite EditOp. The
/// caller transfers ownership of `ops` (allocated from `alloc`); the resulting
/// op frees it in `deinit`.
pub fn makeComposite(alloc: std.mem.Allocator, ops: []EditOp) EditOp {
    return .{ .composite = .{ .ops = ops, .alloc = alloc } };
}
