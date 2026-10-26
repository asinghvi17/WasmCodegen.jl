#!/usr/bin/env python3
"""Compile the transferred SciML state and compare standalone C trajectories."""
import json
from run_experiments import JULIA, ROOT, run


def main():
    directory = ROOT / ".task/native-build/lorenz-transferred"
    directory.mkdir(parents=True, exist_ok=True)
    row = {"build": run([JULIA, "--startup-file=no", "--project=.task/native-env", "proto/transfer/lorenz_native.jl"], directory / "build.log")}
    if row["build"]["returncode"] == 0:
        row["library_bytes"] = (directory / "liblorenz.so").stat().st_size
        row["bundle_bytes"] = (directory / "states.jls").stat().st_size
        row["compile_c"] = run(["gcc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-I" + str(directory), "proto/lorenz_test.c", "-L" + str(directory), "-llorenz", "-Wl,-rpath,$ORIGIN", "-lm", "-o", str(directory / "test")], directory / "compile-c.log")
        if row["compile_c"]["returncode"] == 0:
            row["run_c"] = run([str(directory / "test")], directory / "c-test.log", directory / "c-stderr.log")
            if row["run_c"]["returncode"] == 0:
                output = (directory / "c-test.log").read_text()
                start = output.index("[")
                actual, _ = json.JSONDecoder().raw_decode(output[start:])
                expected = json.loads((directory / "reference.json").read_text())
                assert len(actual) == len(expected) == 2
                assert all(len(a) == len(b) == 401 for a,b in zip(actual, expected))
                differences = [abs(x-y) for a,b in zip(actual, expected) for p,q in zip(a,b) for x,y in zip(p,q)]
                row["max_abs_error"] = max(differences)
                row["compared_values"] = len(differences)
    row["pass"] = row.get("max_abs_error", float("inf")) < 1e-8
    (ROOT / "proto/results/native-lorenz-transferred.json").write_text(json.dumps(row, indent=2) + "\n")
    print("Lorenz transferred native", "PASS" if row["pass"] else "FAIL", flush=True)
    if not row["pass"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
