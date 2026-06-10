#!/usr/bin/env python3
"""Enrich a scoreboard's run-metadata.json with publication-grade git/toolchain
info — the fields compare_min.py intentionally DEFERS (branch/commit/dirty/zig
version/os/cpu) to keep the benchmark missing-CSV guard non-blocking on Windows.

Run this as a POST-campaign publication step (slow git/wmic probes are fine here):
    python tools/analysis/publish_metadata.py <scoreboard_dir> [<scoreboard_dir> ...]

For each dir it reads run-metadata.json (if present, else starts fresh), fills the
deferred fields, records the dirty working-tree file list (critical: the bench may
measure an UNCOMMITTED tree — see LEDGER 'measure-what-ships'), and writes it back.
A `reproducible` flag is set true only when the tree is clean (commit fully
describes what was measured)."""
import json, os, sys, platform, subprocess, datetime

ZIG = r"C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe"


def sh(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True,
                                       stderr=subprocess.DEVNULL).strip()
    except Exception:
        return None


def git_meta():
    dirty = sh("git status --short -- src bench build.zig") or ""
    dirty_files = [ln[3:] for ln in dirty.splitlines() if ln.strip()]
    return {
        "branch": sh("git rev-parse --abbrev-ref HEAD"),
        "commit": sh("git rev-parse HEAD"),
        "commit_short": sh("git rev-parse --short HEAD"),
        "diverged_from_master": sh(
            "git rev-list --left-right --count master...HEAD"),
        "dirty_file_count": len(dirty_files),
        "dirty_files": dirty_files,
        "reproducible": len(dirty_files) == 0,
    }


def enrich(meta):
    g = git_meta()
    meta["branch"] = g["branch"]
    meta["commit"] = g["commit"]
    meta["commit_short"] = g["commit_short"]
    meta["diverged_from_master_LRcount"] = g["diverged_from_master"]
    meta["dirty_file_count"] = g["dirty_file_count"]
    meta["dirty_files"] = g["dirty_files"]
    meta["reproducible"] = g["reproducible"]
    meta.pop("git_probe_note", None)
    meta.pop("dirty_note", None)
    meta.pop("system_probe_note", None)
    meta["os"] = platform.platform()
    meta["cpu"] = platform.processor() or sh("wmic cpu get name")
    meta["logical_cores"] = os.cpu_count()
    meta["zig_version"] = sh(f'"{ZIG}" version')
    meta["msvc_cl"] = sh("cl 2>&1 | findstr /C:Version") or "/arch:AVX2 (see CMakeCache)"
    meta["published_utc"] = datetime.datetime.now(
        datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
    return meta


def main():
    dirs = sys.argv[1:]
    if not dirs:
        print("usage: publish_metadata.py <scoreboard_dir> [...]")
        sys.exit(2)
    for d in dirs:
        path = os.path.join(d, "run-metadata.json")
        meta = {}
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as f:
                meta = json.load(f)
        meta = enrich(meta)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(meta, f, indent=2)
        warn = "" if meta["reproducible"] else \
            f"  !! NOT reproducible: {meta['dirty_file_count']} dirty file(s)"
        print(f"enriched {path}  branch={meta['branch']} "
              f"commit={meta['commit_short']}{warn}")


if __name__ == "__main__":
    main()
