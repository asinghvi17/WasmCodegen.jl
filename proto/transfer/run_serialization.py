#!/usr/bin/env python3
"""Each producer and consumer is a separate ordinary Julia process."""
import json
from pathlib import Path
from run_experiments import JULIA, ROOT, run


def main():
    rows = {}
    for kind in ("named", "closure", "rgf", "rgf-dropped", "sciml"):
        directory = ROOT / ".task/serialization-probe" / kind
        directory.mkdir(parents=True, exist_ok=True)
        row = {}
        for action in ("produce", "consume"):
            row[action] = run([JULIA, "--startup-file=no", "--project=.task/app-env", "proto/transfer/serialization_probe.jl", kind, action, str(directory / "state.jls")], directory / (action + ".log"))
            if row[action]["returncode"] != 0:
                break
        row["pass"] = all(action in row and row[action]["returncode"] == 0 for action in ("produce", "consume"))
        bundle = directory / "state.jls"
        if bundle.exists():
            row["bundle_bytes"] = bundle.stat().st_size
        rows[kind] = row
        print(kind, "PASS" if row["pass"] else "FAIL", flush=True)
        (ROOT / "proto/results/serialization-transfer.json").write_text(json.dumps(rows, indent=2) + "\n")
    directory = ROOT / ".task/serialization-probe/named"
    negative = run([JULIA, "--startup-file=no", "--project=.task/app-env", "proto/transfer/serialization_probe.jl", "named", "consume-without-source", str(directory / "state.jls")], directory / "missing-source.log")
    negative["expected"] = "failure: named callable requires its runtime module definitions"
    negative["pass"] = negative["returncode"] != 0 and "CallableGraphs" in (directory / "missing-source.log").read_text()
    rows["missing_runtime_source"] = negative
    print("missing_runtime_source", "PASS (expected failure)" if negative["pass"] else "FAIL", flush=True)
    (ROOT / "proto/results/serialization-transfer.json").write_text(json.dumps(rows, indent=2) + "\n")
    directory = ROOT / ".task/serialization-probe/build-only-type"
    directory.mkdir(parents=True, exist_ok=True)
    args = [JULIA,"--startup-file=no","--project=.task/app-env","proto/transfer/serialization_probe.jl","build-only-type"]
    produce = run(args + ["produce", str(directory / "state.jls")],directory / "produce.log")
    consume = run(args + ["consume", str(directory / "state.jls")],directory / "consume.log")
    negative = {"produce":produce,"consume":consume,"expected":"unavailable setup-only package type fails reconstruction"}
    negative["pass"] = produce["returncode"] == 0 and consume["returncode"] != 0 and "SetupOnlyTypes" in (directory / "consume.log").read_text()
    rows["build_only_type"] = negative
    print("build_only_type", "PASS (expected failure)" if negative["pass"] else "FAIL",flush=True)
    (ROOT / "proto/results/serialization-transfer.json").write_text(json.dumps(rows,indent=2)+"\n")
    if not all(row["pass"] for row in rows.values()):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
