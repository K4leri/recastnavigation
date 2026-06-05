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
                markAreaDirty();
            },
            .flag_remove => |f| {
                poly_flags.removeFlag(f.bit_index);
                markAreaDirty();
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
                markAreaDirty();
            },
            .flag_remove => |f| {
                poly_flags.restoreFlag(f.bit_index, f.flag.name(), f.flag.builtin);
                markAreaDirty();
            },
        }
    }

    /// Free any heap-owned data. Currently a no-op (all variants are POD value
    /// copies), kept so the UndoStack frees evicted ops uniformly.
    pub fn deinit(self: *EditOp) void {
        _ = self;
    }

    /// Short human label for the panel tooltip ("Undo: Add Volume").
    pub fn name(self: EditOp) []const u8 {
        return switch (self) {
            .add_volume => "Add Volume",
            .delete_volume => "Delete Volume",
            .add_offmesh => "Add Off-Mesh Link",
            .delete_offmesh => "Delete Off-Mesh Link",
            .area_add => "Add Area Type",
            .area_edit => "Edit Area Type",
            .area_remove => "Remove Area Type",
            .flag_add => "Add Poly Flag",
            .flag_remove => "Remove Poly Flag",
        };
    }
};
