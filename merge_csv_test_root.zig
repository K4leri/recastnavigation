//! Standalone test root for the merge_csv tool (`tools/analysis/merge_csv.zig`).
//!
//! Why a repo-root shim? The tool's test
//! (`test/integration/merge_csv_test.zig`) imports the tool via the relative path
//! `../../tools/analysis/merge_csv.zig`. Zig 0.16 forbids a file from importing
//! outside its MODULE ROOT DIRECTORY (the directory of the module's root source
//! file). Rooting the test module at `test/integration/all.zig` would make
//! `../../tools/...` escape `test/integration/` -> "import of file outside module
//! path".
//!
//! This file sits at the REPO ROOT, so when build.zig roots the `test-merge-csv`
//! module here the module root directory is the repo root. From there the test
//! file's `../../tools/analysis/merge_csv.zig` resolves to
//! `tools/analysis/merge_csv.zig`, which IS inside the subtree, so the import is
//! legal. (Mirrors `bench_obj_loader_test_root.zig`.)
//!
//! Pure parsing/formatting test over `std`; no recast-nav dependency. Built by the
//! `test-merge-csv` step and folded into the main `test` step.

comptime {
    _ = @import("test/integration/merge_csv_test.zig");
}
