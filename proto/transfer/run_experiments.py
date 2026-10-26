#!/usr/bin/env python3
"""Foreground native build/ABI probe. All raw output stays in .task/native-build."""
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
JULIA = os.environ.get("JULIA", "julia")
ENV = os.environ.copy()
ENV["JULIA_DEPOT_PATH"] = str(ROOT / ".task/depot") + ":" + ENV.get("JULIA_DEPOT_PATH", str(Path.home() / ".julia"))
ENV["JULIA_PKG_OFFLINE"] = "true"
ENV["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
ENV["JULIA_NUM_PRECOMPILE_TASKS"] = "2"


def run(cmd, log, stderr_log=None):
    start = time.monotonic()
    with log.open("w") as out:
        if stderr_log is None:
            result = subprocess.run(cmd, cwd=ROOT, env=ENV, stdout=out, stderr=subprocess.STDOUT)
        else:
            with stderr_log.open("w") as err:
                result = subprocess.run(cmd, cwd=ROOT, env=ENV, stdout=out, stderr=err)
    row = {"command": cmd, "returncode": result.returncode,
           "seconds": time.monotonic() - start, "log": str(log.relative_to(ROOT))}
    if stderr_log is not None:
        row["stderr_log"] = str(stderr_log.relative_to(ROOT))
    return row


def main():
    rows = {}
    for variant in ("baseline", "image-local-bad", "transferred-bad"):
        directory = ROOT / ".task/native-build" / variant
        directory.mkdir(parents=True, exist_ok=True)
        row = run([JULIA, "--startup-file=no", "--project=.task/native-env", "proto/transfer/build.jl", variant], directory / "build.log")
        text = (directory / "build.log").read_text(errors="replace")
        row["expected"] = "safe trim failure from dynamic initializer" if variant == "image-local-bad" else "build and C pass"
        if variant == "image-local-bad":
            row["pass"] = row["returncode"] != 0 and "Verifier error" in text and "StagedBuildOnlyBad" in text and "CALLBACK" in text
        elif row["returncode"] == 0:
            library = directory / "libtransfer.so"
            row["library_bytes"] = library.stat().st_size
            row["compile_c"] = run(["gcc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-I" + str(directory), "proto/transfer/test.c", "-L" + str(directory), "-ltransfer", "-Wl,-rpath,$ORIGIN", "-lm", "-o", str(directory / "test")], directory / "compile-c.log")
            row["run_c"] = run([str(directory / "test")], directory / "c-test.log") if row["compile_c"]["returncode"] == 0 else None
            row["pass"] = row["run_c"] is not None and row["run_c"]["returncode"] == 0
        else:
            row["pass"] = False
        setup_log = directory / "setup.log"
        if setup_log.exists():
            row["setup_calls"] = setup_log.read_text().splitlines()
        rows[variant] = row
        print(variant, "PASS" if row["pass"] else "FAIL", flush=True)
        (ROOT / "proto/results/native-transfer.json").write_text(json.dumps(rows, indent=2) + "\n")
    if not all(row["pass"] for row in rows.values()):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
