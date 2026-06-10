#!/usr/bin/env python3
"""Capture run metadata for a benchmark publication. Usage:
    python capture_run_metadata.py <out.json>
Emits CPU/OS/toolchain/commit so a published number is reproducible/comparable."""
import json, os, sys, platform, subprocess, datetime

def sh(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True,
                                       stderr=subprocess.DEVNULL).strip()
    except Exception:
        return None

def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "run-metadata.json"
    zig = r"C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe"
    md = {
        "captured_utc": datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z'),
        "os": platform.platform(),
        "cpu": platform.processor() or sh("wmic cpu get name"),
        "logical_cores": os.cpu_count(),
        "zig_version": sh(f'"{zig}" version'),
        "msvc_cl": sh("cl 2>&1 | findstr /C:Version") or "see compare.sh /arch:AVX2",
        "python": platform.python_version(),
        "git_commit": sh("git rev-parse --short HEAD"),
        "git_branch": sh("git rev-parse --abbrev-ref HEAD"),
        "note": "turbo/SMT state is NOT auto-detected — record it manually if pinned.",
    }
    with open(out, "w", encoding="utf-8") as f:
        json.dump(md, f, indent=2)
    print(f"wrote {out}")
    print(json.dumps(md, indent=2))

if __name__ == "__main__":
    main()
