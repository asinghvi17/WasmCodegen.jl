Native backend and transferred setup experiment

`native.jl` implements `build(spec, ::NativeLibrary; output_dir, project,
mode=ImageLocal(), trim_mode="safe", bundle=false)`. It assumes the common
module includes `transfer.jl` before `native.jl`; both are runtime-free frontend
implementation files. Native image source includes only `spec.source`, shared
kernel source, concrete baked state globals, and C adapters. `STATE` is bound to
the actual state vector element type. `GENERATIONS`, `RESET`, and `OP_1...` follow
the agreed kernel contract.

Transferred setup runs a generated producer subprocess under `project`, captures
its log in the output directory, serializes `states.jls`, and validates the
reconstructed vector in the driver via `validate_states`. The generated image
loads Serialization and the runtime source before deserializing that bundle.
ImageLocal calls setup in image top level, with concrete/same-type/capacity
checks. No JuliaC or frontend import occurs in either producer or image source.

Result fields: `library`, `build_source`, `header`, `manifest`, `dir`, `setup_mode`,
`transfer_bundle`. The target manifest passed to `write_manifest` is a NamedTuple
describing signatures, status values, pointer rules, and setup mode, nested under
`native` as required by common manifest merging. Scalar-only common exports mean
the probe's clear operation returns Int32(0) rather than Nothing.

Both producers check each setup result's exact type before assigning into the
concrete vector, so an implicit conversion cannot hide heterogeneous setup
results. The generated image additionally checks concrete type, capacity,
reset applicability, and export methods. The common kernel performs pool and
generation handling; native entrypoints catch exceptions and store results only
when status is zero. All C functions return int32_t, with statuses 0, -1, -2,
-3, and -4. The generated header and `targets.native` manifest describe the
physical signatures and output pointer requirements. Host calls must be serialized.

Tested on Linux x86_64 with the direct Julia 1.12.7 executable, JuliaC 0.3.12,
PackageCompiler 2.4.1, and GCC. Application lock versions include
OrdinaryDiffEqTsit5 2.1.4, OrdinaryDiffEqCore 4.17.0, SciMLBase 3.53.1,
DiffEqBase 7.20.1, StaticArrays 1.9.20, SciMLLogging 2.1.0, and
RuntimeGeneratedFunctions 0.5.26. Parent prepared `.task/native-env` and
`.task/app-env`; the probes used the task depot followed by the existing depot.
No dependency download was performed by this worker.

Run these exact commands from the checkout root after the shared environments
are ready (the Python runners set the depot prefix and offline mode themselves):

```bash
python3 proto/transfer/run_experiments.py
python3 proto/transfer/run_serialization.py
python3 proto/transfer/run_lorenz_native.py
```

Each JSON result records every actual argv, exit code, elapsed time, and log
path. Raw output and binaries stay under `.task/native-build` and
`.task/serialization-probe`; measurement summaries are
`proto/results/native-transfer.json`,
`proto/results/serialization-transfer.json`, and
`proto/results/native-lorenz-transferred.json`.

The native runner invokes the direct executable with
`--startup-file=no --project=.task/native-env proto/transfer/build.jl VARIANT`.
Both native drivers use JuliaC's exact recipe
`ImageRecipe(output_type="--output-lib", trim_mode="safe",
add_ccallables=true, cpu_target="native", project=app_project, export_abi=...)`,
then `compile_products`, `LinkRecipe`, and `link_products`. Generated sources
load neither JuliaC nor ProgramBuild. JuliaC performs the image subprocess and
forwards `--trim=safe`; no initializer suppression or unsafe trim is used.

| Native probe | Build result | Standalone C | Library bytes |
|---|---|---|---:|
| baseline, ImageLocal | pass | pass | 1,844,520 |
| bad initializer, ImageLocal | expected safe trim failure, exit 1 | no library | — |
| same bad initializer, Transferred | pass | pass | 1,848,312 |
| Lorenz integrators, Transferred | pass | pass, both trajectories compared | 2,622,632 |

These are exact unbundled `.so` sizes from the final run, excluding libjulia
and its dependencies. Small size differences between runs do not identify retained
methods. The final simple builds took approximately 12.5/12.7/14.4 seconds;
the Lorenz transferred build took 20.5 seconds with warm package caches.

`TransferProgram.jl` contains runtime definitions and a lazy `spec()` reference to
`Main.ProgramBuild`. Only `setup` extends LOAD_PATH and imports a verbatim copy of the supplied
`StagedBuildOnlyBad` fixture from `transfer/fixtures`, then calls its callback
and uses the result as the returned state's initial value. Its dynamic `Ref{Any}` initializer is therefore
loaded in the ImageLocal image process and in the Transferred producer, while
the transferred image only includes the runtime module and deserializes the
four accumulators. Setup uses BigFloat to compute a coefficient, retaining two
Float64 fields per accumulator.

ImageLocal's expected failure is specifically:

```text
Verifier error #1: unresolved call from statement
(Base.getfield(StagedBuildOnlyBad.CALLBACK, :x)::Any)(1.0)::Any
 [1] __init__()
```

The setup logs still have exactly four lines after the C test. Baseline has
`imaging=1 bad_loaded=false`, bad ImageLocal has `imaging=1 bad_loaded=true`, and
bad Transferred has `imaging=0 bad_loaded=true`. Thus setup ran in the ordinary
producer for Transferred, never during its image compilation or C execution.
A byte scan also found no `StagedBuildOnlyBad` token in that library; the safe
trim success is the stronger evidence that the dynamic initializer was excluded.

The simple C harness checks four slots, exhaustion, two independent accumulators,
zero/out-of-range/wrong-generation/stale handles, null outputs, unchanged outputs
on invalid/exhausted/exception results, a throwing export, clear/reset, and 1,000
destroy/create cycles. It links with
`gcc -std=c11 -Wall -Wextra -Werror -I<dir> proto/transfer/test.c -L<dir>
-ltransfer '-Wl,-rpath,$ORIGIN' -lm -o <dir>/test`.
No explicit `jl_init` call is made. The shared scalar-only frontend does not
currently expose a Nothing/void export; this harness returns Int32 from clear.

For SciML, `serialization_probe.jl` includes the parent's `LorenzProgram.jl` in
each fresh process. One process serializes two fully constructed integrators;
the reader deserializes them, solves one, compares all 401 trajectory points
component by component against an ordinary fresh setup with exact equality,
checks the second integrator remains at t=0, and resets the first. The bundle
was 11,168 bytes. This tests the supplied named Lorenz RHS, FullSpecialize,
Tsit5, SVector state, quiet logging and NoInit configuration.

The full native transferred Lorenz probe separately serializes four integrators
(20,344-byte bundle), compiles a safe-trim library, and runs the parent's
`proto/lorenz_test.c`. Both parameter sets produce 401 points; all **2,406 scalar
values match the ordinary Julia reference exactly** (maximum absolute error 0).
The C test also passes null/exception, stale handle, isolation, pool exhaustion,
reset, and 1,000 reuse checks. It uses the same GCC flags as above with
`proto/lorenz_test.c` and `-llorenz`. The runner captures stdout and stderr
separately because the C harness emits trajectory JSON and a diagnostic line;
the initial combined capture interleaved those streams and failed JSON parsing,
then the corrected full rerun passed.

| Ordinary fresh-process callable probe | Result | Bundle bytes |
|---|---|---:|
| Named module-level function | pass, deserialize and call | 43 |
| Closure capturing a Float64 offset | pass, deserialize and call | 84 |
| RuntimeGeneratedFunction with retained expression | pass, fresh cache | 303 |
| RuntimeGeneratedFunction after drop_expr | pass, fresh cache | 314 |
| Named function with runtime module omitted in reader | expected failure, exit 1 | — |

`CallableGraphs.jl` initializes the RGF cache module in both processes but creates
no RGF at top level. The reader therefore starts with definitions and an empty
expression cache. RGF 0.5.26's Serialization methods successfully reconstruct
both retained and dropped-expression forms. The negative source control reports
`UndefVarError: CallableGraphs not defined in Main`, establishing the need to
provide matching runtime module/type/function definitions before deserialization.

The transfer format remains Julia Serialization for a controlled, same-version,
same-platform build pipeline, rather than a stable portable state schema.
The frontend still requires setup/reset/exports to be named module-level
functions through `functionref`; the captured closure experiment concerns values
inside serialized graphs, not accepting closures as frontend entrypoints.
Callable probes establish ordinary-process serialization, not safe trimming of
arbitrary closure/RGF runtime workloads. The native Lorenz test uses a named RHS.

Validation checks the state vector's shape, concrete element type and available
methods. It does not prove a graph has no IO, pointers, external resources,
callbacks with hidden dependencies, process-local caches, or relevant RNG state.
No general resource reconstruction, version migration, checkpoint/restart,
arbitrary SciML solver/callback coverage, or bundling was tested. Returned states
whose types/functions belong to build-only packages still require matching runtime
definitions; imports at runtime source top level still run in the image process.
Transferring state isolates setup imports for these programs and does not remove
dependencies or trim failures on code genuinely needed during runtime.

The final parent integration adds an explicit setup-only type control in
`transfer/fixtures/SetupOnlyTypes`: a package-defined state serializes in the
producer and fails in a clean reader where the package is unavailable. The
original dynamic-initializer fixture is copied verbatim so reproducing the
spike does not require the untracked input prototype trees. Final artifact
sizes are in `results/artifacts.json` and `results/native-transfer.json`; small
metadata differences across the full integration rerun supersede the earlier
standalone figures above.
