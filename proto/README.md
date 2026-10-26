# Shared Julia program build spike

`ProgramBuild` supplies one declaration and one generated pool/lifecycle kernel
for WasmGC and JuliaC native libraries. No compiler source was changed.
`LorenzProgram.jl` is the identical runtime/program source for both builds;
`build.jl` creates one spec and passes that object to both targets.

## User-facing program and build API

The complete 45-line program file (setup returns the concrete SciML integrator):

```julia
module LorenzProgram

using OrdinaryDiffEqTsit5, StaticArrays, SciMLLogging
using OrdinaryDiffEqTsit5: SciMLBase
using DiffEqBase: DEVerbosity


lorenz(u, p, t) = SVector{3,Float64}(p[1] * (u[2] - u[1]),
    u[1] * (p[2] - u[3]) - u[2], u[1] * u[2] - p[3] * u[3])

# Four time units keep the full trajectory comparison ahead of chaotic divergence.
const CONFIG = (; t_end=4.0, saveat=0.01)
const DEFAULT_P = (10.0, 28.0, 8 / 3)

function setup(config)
    prob = ODEProblem(ODEFunction{false,SciMLBase.FullSpecialize}(lorenz),
        SVector{3,Float64}(1.0, 1.0, 1.0), (0.0, config.t_end), DEFAULT_P)
    return init(prob, Tsit5(); saveat=config.saveat, abstol=1e-8, reltol=1e-8,
        verbose=DEVerbosity(SciMLLogging.None()), initializealg=SciMLBase.NoInit())
end

function reset!(s)
    s.p = DEFAULT_P
    SciMLBase.reinit!(s, SVector{3,Float64}(1.0, 1.0, 1.0))
    return nothing
end

function solve!(s, σ::Float64, ρ::Float64, β::Float64, x0::Float64)::Int32
    s.p = (σ, ρ, β)
    SciMLBase.reinit!(s, SVector{3,Float64}(x0, 1.0, 1.0))
    SciMLBase.solve!(s)
    return Int32(length(s.sol.u))
end

point(s, i::Int32, k::Int32)::Float64 = s.sol.u[i][k]

function spec(n=4)
    (; ProgramSpec, BakedPool, ExportSpec) = Main.ProgramBuild
    ProgramSpec(; name="lorenz", source=@__FILE__, setup, config=CONFIG, instances=BakedPool(n),
    reset=reset!, exports=[
        ExportSpec(:solve, solve!, (Float64, Float64, Float64, Float64); returns=Int32),
        ExportSpec(:point, point, (Int32, Int32); returns=Float64)])
end

end
```

```julia
include("paths.jl") # loads the builder; runtime image never includes this file
include("LorenzProgram.jl")
spec = LorenzProgram.spec()
build(spec, WasmGC(); output_dir="proto/build/lorenz")
build(spec, NativeLibrary(); output_dir="proto/build/lorenz", project=".task/app-env")
```

The native staging policy can be changed independently:

```julia
build(spec, NativeLibrary(); output_dir="proto/build/lorenz-transfer",
      project=".task/app-env", mode=Transferred())
```

The source file keeps its builder reference inside `spec()`, which is never
called by the image process. Its imports define runtime types and methods.
Build-only imports must happen inside setup, as in `transfer/TransferProgram.jl`.
An unconditional build-only import in the runtime source defeats isolation.

## Measured results

Linux x86_64, Julia **1.12.7**, JuliaC **0.3.12** (Git tag), Node **26.10.0**,
Binaryen **0.130.0**. Both backends use safe trimming; Wasm additionally uses
`verify=:error` and `on_unsupported=:error`. Runtime dependencies are locked in
`locks/app.toml`; builder dependencies/source hashes are in the other locks.

| Build/probe | Artifact bytes | Safe trim | Execution/comparison |
| --- | ---: | --- | --- |
| Lorenz WasmGC, pool 4 | 130,655 | pass; zero diagnostics | Node passes; 2,406 values, max error 1.7888e-12 vs Julia/native |
| Same spec, native ImageLocal | 2,691,528 | pass | C passes; 2,406 values exactly match Julia |
| Same spec, native Transferred | 2,623,288 | pass | C passes; 2,406 values exactly match Julia |
| Filter without dynamic initializer | 1,844,520 | pass | C passes |
| Filter with dynamic initializer, ImageLocal | no library | expected failure in `StagedBuildOnlyBad.__init__` | unresolved `CALLBACK::Any` call |
| Same filter, Transferred | 1,848,312 | pass | C passes; setup log has four `imaging=0` calls |
| SciML ordinary-process Serialization round-trip | 11,168 (two states) | n/a | solve/reset/independence pass; all 1,203 trajectory values identical |

These are individual unbundled output sizes, including image metadata, excluding
libjulia and its dependencies. Build paths and metadata can change size by small
amounts. The native size difference is not a controlled retention measurement.
The four-state SciML transfer bundle is **20,344 bytes**. Wasm emits 82 Julia
methods and serializes 234 objects; its measured compile interval is 52.916 s,
including compiler JIT, validation and optimization, excluding loading/setup.
Concurrent experiments ran on this worker, so this is not a performance benchmark.

Node verifies separate module instances, two live trajectories, stale/zero/wrong
and out-of-range handles, exhaustion, reset/reuse and the generated class errors.
C verifies the same lifecycle, independent state, unchanged outputs on failures,
null pointers, an actual bounds exception, and 1,000 create/destroy cycles.
Julia has 25 lifecycle/declaration assertions, including generation exhaustion,
and three physical ABI serialization assertions.
The root experiment also verifies unsigned JS results and a user export named
`lookup`. Machine-readable evidence is under `results/`; trajectories and binaries
are reproducible under ignored `build/` and logs under ignored `.task/`.

## Shared source size

Counts include comments and blank lines, and exclude generated output, tests,
examples, dependencies and project manifests:

| Framework source | Lines | Responsibility |
| --- | ---: | --- |
| Shared `ProgramBuild.jl` | 178 | spec validation, function/config references, pool/handle/kernel generation, logical manifest merge |
| Wasm `wasm.jl` | 116 | Julia staging/lowering, strict compiler entries, physical signatures, JS loader |
| Native `native.jl` | 135 | image source, C status/out adapters, header, JuliaC recipe |
| Native `transfer.jl` | 38 | producer process and serialized state bundle |
| Total framework | 467 | 178 shared; 116 Wasm-specific; 173 native-specific |
| Shared Lorenz program (separate) | 45 | setup, reset, solve, point and declaration |

`results/sharing.json` records source hashes and verifies that both native image
sources contain the exact kernel emitted for Wasm and include the same program
file. Target code never copies the numerical program or lifecycle algorithm.

## Shared semantics and physical interfaces

`results/lorenz.json` has one `logical` declaration and separate
`targets.wasm_gc` / `targets.native` physical sections. Building the second target
merges its section and rejects a different logical spec in that directory.
`results/program.h` and `results/lorenz.mjs` are generated output samples.

| Shared logical operation | Wasm physical signature | Native physical signature |
| --- | --- | --- |
| create → UInt64 | `() → (i32 status, i64 handle)` | `int32_t lorenz_create(uint64_t *out)` |
| destroy(UInt64) | `(i64) → (i32 status, i32 unused)` | `int32_t lorenz_destroy(uint64_t h)` |
| solve(handle, four Float64) → Int32 | `(i64,f64,f64,f64,f64) → (i32,i32)` | `int32_t lorenz_solve(uint64_t, double, double, double, double, int32_t*)` |
| point(handle, Int32, Int32) → Float64 | `(i64,i32,i32) → (i32,f64)` | `int32_t lorenz_point(uint64_t, int32_t, int32_t, double*)` |

Both targets use UInt64 `generation << 32 | one_based_slot`; zero is invalid.
Generation wrap to zero permanently retires the slot. Create resets a baked state;
it never calls setup. Destroy invalidates the handle. States must be independent.
Calls are serialized; handles are scoped to a single artifact instance.
Shared status numbers: 0 success, -1 invalid handle, -2 full pool, -3 null output,
-4 exception. Wasm implements the first three applicable lifecycle results;
application exceptions propagate through Wasm. Native catches application/reset
exceptions and translates them to -4; outputs are written only on success.

## Transferred setup and its limits

`Transferred()` generates an ordinary Julia producer process under the selected
project. It includes the same program definitions, runs setup once per slot,
serializes a concretely typed vector, and exits. The clean JuliaC image process
includes runtime definitions and Serialization, then deserializes the vector.
It never invokes setup or imports the fixture. Its generated source does not
import ProgramBuild, JuliaC, JSON or the build-only package. Neither initializer
suppression nor unsafe trimming is used.

The dynamic initializer fixture is reused from the supplied prototype. In
ImageLocal its initializer becomes a trim root independently of the declared
exports and fails verification. In Transferred it executes only in the producer.
The returned filter state contains only runtime-defined fields. The SciML
integrator also survives this boundary, including embedded functions and solver
caches, with the pinned versions and quiet logging configuration used here.

The supported contract is a Julia state graph whose concrete type definitions,
callable method definitions and required packages are loaded in the image before
deserialization.
The producer and consumer must use compatible Julia/package/source versions.
Serialization is a staging format here, not a portable deployment format.
Pointers, IO, external resources and tasks need reconstruction and are outside
this prototype. No recursive graph validator enforces this contract yet.

Named functions, source-defined captured closures and the exercised
RuntimeGeneratedFunctions values **do round-trip** in ordinary processes when
their runtime definitions/cache modules are loaded. They are not categorically
unserializable. These probes alone do not establish safe-trim support for every
such callable graph. A negative probe also serializes a package-defined state and fails to deserialize
it with that setup-only package absent. A missing runtime module/method/type or an unavailable
build-only package type breaks clean reconstruction. Dynamically generated
methods and RGF cache/expression availability need an explicit runtime strategy.
See `NATIVE-NOTES.md` and `results/serialization-transfer.json` for exact controls.

## Reproduce

All commands run at the repository root. This worker's ordinary `julia` launcher
cannot lock its read-only juliaup installation, so commands used the installed
binary directly. The available 1.13 installations were rc3 and 1.13.1; an optional
`JULIAUP_DEPOT_PATH="$PWD/.task/juliaup" juliaup add 1.13.0` attempt could not fetch
`julialang-s3.julialang.org`. Every reported result uses **1.12.7**, with no 1.13 claim.
GitHub/package/artifact downloads for project dependencies succeeded.

```bash
export JULIA=/home/asinghvi17/.julia/juliaup/julia-1.12.7+0.x64.linux.gnu/bin/julia
export JULIA_DEPOT_PATH="$PWD/.task/depot:${JULIA_DEPOT_PATH:-$HOME/.julia}"
export JULIA_PKG_PRECOMPILE_AUTO=0
export JULIA_NUM_PRECOMPILE_TASKS=2
bash proto/run.sh
```

`run.sh` contains every build and C/Node command, in execution order. The
substantive commands are:

```bash
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
```

Bootstrap reconstructs the locked runtime and builder environments. Initial native
bootstrap used `Pkg.add(url="https://github.com/JuliaLang/JuliaC.jl", rev="v0.3.12")`
because the installed registry stopped at 0.3.10. Standalone package instantiation
and `using ProgramBuild` also passed with `--project=proto/ProgramBuild`.

## Remaining design gaps

* Common host types are the intersection tested here: Int32/UInt32, Int64/UInt64,
  Float32/Float64 scalar arguments and results. No aggregate ABI, void export,
  dynamic state allocation, finalization, concurrency or state synchronization.
* Native functions must be named module bindings available from `source`; frontend
  declaration code is lazy and deliberately absent from image imports. Dependency
  classification is a program-author contract, not an automatic dependency split.
* Wasm exception-to-status parity is unfinished. Native discards exception detail;
  a throwing operation can partially mutate its state on either target.
* Called private helpers compile without being exported. Independent unreachable
  roots have no supported non-exporting WasmCodegen API: `roots=` raises MethodError,
  and adding an `Entry` also exports it. This was rerun, including Node inspection.
* The native library still needs Julia runtime libraries and currently targets the
  build CPU. Bundling, relocatability and deployment packaging were not exercised.
* Safe trimming remains mandatory for runtime methods. Transfer does not repair
  dynamic solver logging or other code actually reachable at runtime. The tested
  Lorenz program disables logging using `DEVerbosity(SciMLLogging.None())`.

The final full foreground runner exited 0; its console output is preserved in
`results/full-run.txt`. The final ABI-only correction was also validated by the
three JSON assertions, and the committed manifest sample was regenerated with
`ProgramBuild.wasm_manifest(spec)` after that correction.
