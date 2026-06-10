//! Standalone test root for the bench .obj loader (`bench/obj_loader.zig`).
//!
//! Why a repo-root shim? The loader's test
//! (`test/integration/obj_loader_test.zig`) imports the loader via the relative
//! path `../../bench/obj_loader.zig`. Zig 0.16 forbids a file from importing
//! outside its MODULE ROOT DIRECTORY (the directory of the module's root source
//! file). Rooting the test module at `test/integration/all.zig` makes
//! `../../bench` escape `test/integration/` -> "import of file outside module
//! path".
//!
//! This file sits at the REPO ROOT, so when build.zig roots the
//! `test-obj-loader` module here the module root directory is the repo root.
//! From there the test file's `../../bench/obj_loader.zig` resolves to
//! `bench/obj_loader.zig`, which IS inside the subtree, so the import is legal.
//!
//! Pure parsing test over `std`; no recast-nav dependency. Built by the
//! `test-obj-loader` step and folded into the main `test` step.

comptime {
    _ = @import("test/integration/obj_loader_test.zig");
}
