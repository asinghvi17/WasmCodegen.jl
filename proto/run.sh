#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${JULIA:=julia}"
export JULIA
export JULIA_DEPOT_PATH="$PWD/.task/depot:${JULIA_DEPOT_PATH:-$HOME/.julia}"
export JULIA_PKG_PRECOMPILE_AUTO=0
export JULIA_NUM_PRECOMPILE_TASKS=2
mkdir -p .task proto/results
"$JULIA" --startup-file=no proto/bootstrap.jl
"$JULIA" --startup-file=no --project=.task/app-env proto/runtests.jl
"$JULIA" --startup-file=no --project=.task/app-env proto/build.jl reference wasm native
node proto/test.mjs
cc -std=c11 -Wall -Wextra -Werror -Iproto/build/lorenz proto/lorenz_test.c \
  -Lproto/build/lorenz -llorenz '-Wl,-rpath,$ORIGIN' -lm -o proto/build/lorenz/lorenz_test
proto/build/lorenz/lorenz_test > proto/build/lorenz/native-points.json
"$JULIA" --startup-file=no --project=.task/app-env proto/build.jl transferred
cc -std=c11 -Wall -Wextra -Werror -Iproto/build/lorenz-transfer proto/lorenz_test.c \
  -Lproto/build/lorenz-transfer -llorenz '-Wl,-rpath,$ORIGIN' -lm -o proto/build/lorenz-transfer/lorenz_test
proto/build/lorenz-transfer/lorenz_test > proto/build/lorenz-transfer/native-points.json
python3 proto/compare.py
"$JULIA" --startup-file=no --project=.task/app-env proto/check_roots.jl
node proto/check_roots.mjs
python3 proto/transfer/run_experiments.py
python3 proto/transfer/run_serialization.py
python3 proto/transfer/run_lorenz_native.py
python3 proto/measure.py
git diff --check
