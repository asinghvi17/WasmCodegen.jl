# WasmCodegen.jl design

WasmCodegen compiles Julia programs to WebAssembly with the GC proposal (WasmGC), the
way `juliac --trim` compiles them to native code: from entry points, it collects the
closed world of code they can run, compiles it, and serializes the Julia objects that code
refers to into the binary, so the module starts with the heap the program needs. No Julia
runtime is linked. What libjulia does natively (allocation, GC, object layout, type tags)
is done by WasmGC and by generated code. What the C runtime and libraries do (IO, 128-bit
arithmetic, ...) is a small runtime written in Julia, compiled into the module on demand,
over a few host imports.

The supported subset is what `juliac --trim=safe` accepts (no dynamic dispatch), on
Julia 1.13 (1.12 works too).

It follows JuliaCodegen.jl (Julia's code generator written in Julia) in how values are
represented, SynchJulia.jl and cuTile.jl in how it gets and structures IR, and JuliaC.jl
in how programs are prepared for trimming. WasmBuilder.jl (the LLVM.jl of Wasm) builds and
validates the module. WasmTarget.jl was a reference for edge cases (`docs/EDGE_CASES.md`).

```
entry points (f, argtypes)
  │  in a world with juliac's trim patches (+ the pseudo-runtime's): method definitions
  │  compiler pinned to its own world (the world WasmCodegen was loaded in)
  ▼
collect: CC.compile! under WasmInterpreter    ── juliac's typeinf_ext_toplevel
  │  (native inference; target fact: have_fma = false)
  │  check: juliac's trim verifier, on the native interpreter (trim_check)
  ▼
per function: CodeInfo → IRCode → prepare → StructuredIRCode (IRStructurizer.jl)
  │  prepare: strip exception handling, trap throws, drop unused type computations
  ▼
emit: walk the structured IR → WasmBuilder (validating builder)
  │  runtime functions (Julia) and host imports added on demand
  ▼
image: serialize the referenced objects; start function completes them
  ▼
module bytes (wasm-tools validated; wasm-opt optional)
```

## 1. The program's world: no overlays, patches

Inference is Julia's own: the same `InferenceParams`/`OptimizationParams` as juliac
(`force_enable_inference`), concrete evaluation included (only semi-concrete evaluation is
off), with its own cache owner. The only target-specific fact is `have_fma = false` (Wasm
has no fused multiply-add), folded in `abstract_call_known`.

There is no overlay method table. Overlays taint effects (`nonoverlayed`), which disables
concrete evaluation of everything that may reach them (a `typejoin` that builds a vector
reaching an overlaid `unsafe_copyto!`); and code built on fake native bodies confuses
effects (an overlay's native fallback made an intrinsic look effect-free, and it was
deleted). What overlays would do is done instead:

- **juliac's trim patches** (`src/trim/juliac-*.jl`, from JuliaC.jl): the method
  redefinitions juliac applies in its build process (`invokelatest` as a direct call, no
  logger lookups, trim-friendly `show(::Type)`, raised `max_args`, ...);
- **the pseudo-runtime's patches** (`src/trim/wasm-*.jl`): Base and Core methods
  redefined for what Wasm has no C runtime for, written over runtime primitives. IO:
  Core's standard streams write through `Runtime.IO.write_byte` instead of libuv;
- **lowering in the code generator** of what Base does with pointers and C calls
  (`memmove`, `memset`, `jl_genericmemory_copyto`, `jl_alloc_genericmemory`, string
  conversions), from the IR (section 5);
- **runtime functions** in Julia for what Wasm lacks (128-bit arithmetic, exact `fma`).

Patches are real method definitions: native inference treats them like any method. They
are defined in a new world for a compilation (or a session of compilations,
`with_trim_patches`), the program is inferred in that world, and they are deleted
afterwards (deleting a method that replaced another restores it; the one constant juliac
rebinds, `Base.invokelatest`, is rebound).

**The compiler runs in its own world**: the world WasmCodegen was loaded in. All of
`compile` runs through `invoke_in_world(COMPILER_WORLD, ...)`, so the compiler's native
code stays valid whatever is defined or deleted later (patches, the program, packages
loaded afterwards), as GPUCompiler isolates the compiler. Without this, each patch cycle
invalidated the compiler's own code and every compilation re-JITted it (≈50 s); with it, a
patched compilation of a small function takes about a second.

## 2. Collecting the closed world, checking it

`collect_world` drains a `CompilationQueue` with `CC.compile!` (as juliac's
`typeinf_ext_toplevel`), then completes `:invoke` targets inference kept without source,
to a fixpoint. `CodegenSources` serves `compile!` the sources of CodeInstances cached by
earlier interpreters (uncompressed on demand), so inference results are reused across
compilations. `extend_world!` adds functions later (the runtime's).

`trim_check` is juliac's check, exactly: native inference collects the entry points'
code (`typeinf_ext_toplevel` with `TRIM_UNSAFE`) and juliac's verifier reports dynamic
dispatch. With `Config(verify=:warn)` (the default) it reports; `:error` fails as juliac
`--trim=safe` does. (The verifier on our own collection gives false positives: its fallback
cache only knows CodeInstances of the native cache.)

The code generator then reports every construct it cannot compile, all of them
(`UnsupportedConstructs`), with `trim = :safe` (the default). `trim = :unsafe` compiles
them to traps where they are, as `juliac --trim=unsafe`.

## 3. Structured IR

IRStructurizer recovers `IfOp`/`ForOp`/`WhileOp`/`LoopOp` regions with block arguments;
Wasm control flow is structured, so the lift is direct:

| Structured op | Wasm |
|---|---|
| `IfOp` with `YieldOp`s | `if` with result locals assigned in each arm |
| `LoopOp` (`ContinueOp`/`BreakOp`) | `block $exit (loop $cont ...)` |
| `ForOp` (iv, `slt` bound, step) | `block (loop (br_if exit (iv ≥ upper)) body iv+=step br)` |
| `WhileOp` (before/`ConditionOp`/after) | `block (loop before (if !cond results br exit) after br loop)` |
| `ReturnNode` | `return` |

Carried values are assigned in parallel (all values pushed, then all locals set). Results
of control-flow ops are lists of values read by `getfield(op, i)`. IRStructurizer's
terminator type check is stricter than Julia's IR (a phi's edge value may be wider than
the phi when a branch narrowed it), so that one validation is skipped.

**Exceptions.** For now `throw` traps: `prepare` removes handlers (`EnterNode` edges,
`:leave`, `:pop_exception`, `Upsilon`s; compaction drops the handler blocks), replaces
the thrown value by `nothing`, and removes the computations that only built it (exception
objects, error messages) when they are effect-free or build an exception or a string.
Functions that always throw are still compiled (their effects before the throw happen).
Structured try regions (`TryOp`, IRStructurizer branch `eh-tryop`) are designed and
implemented; lowering them to `try_table`/`catch_ref` with a tag carrying the Julia
exception is next.

## 4. Values

As in JuliaCodegen (and Julia's code generator), a value's representation follows its type:

- **ghost**: singletons and zero-size types (`nothing`, functions without captures,
  unique `Type{T}`): no Wasm value;
- **inline**: concrete immutable types (primitives, tuples, structs, closures) with at
  most 64 leaves: a flat list of Wasm values, its *leaves* (`SVector{3,Float64}` is three
  `f64`s). Never allocated: `getfield` selects leaves, `new` gathers them, calls take and
  return them as multiple values. Tuples whose fields are unique `Type{X}`s (packed varargs)
  are inline too;
- **boxed**: everything else, one reference.

Primitives: 8/16/32-bit integers, `Bool`, `Char` (its bits) are `i32`, kept zero-extended
(masked after arithmetic, sign-extended where signedness matters); 64-bit `i64`; floats
`f32`/`f64`; 128-bit integers two `i64` leaves (low, high), their arithmetic in the
runtime; pointers `i64` (virtual, section 5).

**Objects** are `$JlValue` subtypes: `(struct (field $typeid i32) (field $hash (mut i32)) ...)`.
The type id indexes the closed world's types (for `isa`, `typeof`); the hash is the
identity hash, assigned on first use.

- mutable structs: the header, then their fields' leaves, flattened (mutable, nullable
  references; null is `#undef`);
- inline values stored where the type is abstract: a box (`$Box{T}`, immutable leaves);
  ghosts: one singleton object per type;
- `Memory{T}`: an object holding a Wasm array of the elements; `String` and `Symbol`:
  objects holding a byte array (the same array type as `Memory{UInt8}`, so conversions
  share bytes); `String` `===` compares contents;
- large homogeneous tuples (more than 64 leaves) and tuples of unknown length
  (`Tuple{Vararg{T}}`, e.g. from splatting a vector): an immutable object holding an
  array, which can be indexed at run time; a run-time index into a small inline tuple of
  one element type builds a temporary array;
- type objects (`DataType`s used as values): one interned object per type, holding the type
  id it is.

All types are in one recursion group, so they are nominal.

**Memory layout.** A `Memory{T}`'s array stores, per element: a primitive as its numeric
type (packed `i8`/`i16` for small ones); an inline value whose leaves are stored alike as
its leaves (stride `k`: `SVector{3,Float64}` is 3 `f64`s, as Julia lays it out); other
isbits values as their leaves widened to `i64` (never `#undef`); other inline values
(with references, mixed) as references to boxes; references as references.
`MemoryRef{T}` is inline: the Memory object, its array (so accesses don't load it) and the
element index. `Array` is then Base's own mutable struct, and Base's array code (growth
with `_growend!`, `copyto!`, broadcasting, `sort!`, `cat`) compiles from its Julia source.

## 5. Pointers: provenance

Wasm has no addresses. Base takes pointers into memory (`ptr_or_offset`, `pointer(s)`,
`jl_value_ptr` of a `Ref`) to call C (`memmove`, `memset`, ...) or for alias checks
(`dataids`). A pointer value is a virtual address: each Memory/String object gets a range
from its identity hash shifted by 32 bits, plus the element offset, so comparisons and
differences behave as natively. And a pointer value carries its **origin** through SSA
values (bitcasts, `add_ptr`/`sub_ptr`): the object, array and element it points to. A C
call with pointer arguments (`memmove`, `memset`, `jl_genericmemory_copyto`), a load or
store through a pointer (`pointerref`/`pointerset`) compile from the origins: `array.copy`,
`array.fill`, `array.get`/`set`. A pointer without a known origin (it crossed a call) is
an unsupported construct, never a guess.

## 6. The image: serializing objects

Constants in the IR (literals, `QuoteNode`s, constant globals) and the values of global
variables, and every object reachable from them, are serialized into the module, as juliac
puts them in its image: a program can build data at compile time (an `ODEProblem`, an
integrator after `init`, a table) and the module contains that data, not the code that
built it.

- An inline constant is instructions (its leaves; references inside are `global.get`s).
- An object is one immutable global, initialized by a constant expression (`struct.new`,
  `array.new_fixed` for small arrays), emitted in depth-first postorder so referenced
  objects come first. Identity is preserved (an `IdDict`): an object referenced from
  several places is one object.
- A reference to an object being serialized (a cycle) is null in the initializer and set by
  the module's start function once every global exists. Cycles through immutable objects
  are rejected for now (an allocate-then-patch order over strongly connected components
  would handle them).
- Large numeric arrays are `array.new_default` in the initializer and filled by the start
  function from passive data segments (`array.init_data`); large reference arrays are filled
  by the start function.
- `MemoryRef` constants are (Memory object, array, index); type objects are interned.
- Global variables are mutable globals (one per leaf of the declared type), initialized
  with their value at compile time.
- Not serializable (an error naming the object): pointers, tasks, modules, methods.

## 7. Functions, calls, intrinsics

One Wasm function per CodeInstance; parameters and results are the leaves of the
arguments (the function object too, for closures; varargs packed in a tuple) and of the
return type. `:invoke` calls it, converting representations (boxing for abstract
parameters). Builtins (`getfield`, `setfield!`, `===` (bitwise on floats, by content for
immutables), `isa` (type ids, a generated predicate per abstract type), `tuple`,
`ifelse`, `memoryref*`, `_apply_iterate` into tuples, ...) and intrinsics are emitted
inline, with Julia's semantics where Wasm's differ: over-shifts, saturating float→int,
checked arithmetic, `fpiseq`, IEEE `min`/`max`, division traps.

## 8. The runtime

- **Runtime functions** (`src/runtime/`, module `WasmCodegen.Runtime`): Julia code the
  code generator calls for what Wasm lacks, compiled into the module on demand
  (`runtime_function!` extends the closed world): 128-bit integer arithmetic on `UInt64`
  pairs (multiplication by 32-bit halves, shift-subtract division); `fma` is Base's
  `fma_emulated`.
- **Primitives**: runtime functions whose calls the code generator compiles to host
  imports (module `julia`): `write_byte(fd, byte)`.
- **The pseudo-runtime's patches** (section 1): Base/Core methods over the primitives
  (IO for `Core.stdout`/`Core.stderr`).
- **The host**: a loader instantiating the module with the `julia` imports (the test
  runner's is in `test/runner.mjs`): it buffers bytes per descriptor and decodes them as
  UTF-8.

Next: the task-local RNG (`rand`), exceptions with `try_table`, float parsing, time; a
WASI-style host interface.

## 9. Output, performance

Exports are the entry points under their names, with their leaves as parameters and
results (`i64` is a JavaScript BigInt). `wasm-opt` (Binaryen, without `-all`: it enables
proposals V8 does not ship) shrinks modules by about a quarter; V8's optimizing tier makes
its speed effect small. OrdinaryDiffEq's Tsit5 on the Lorenz system runs within about 1.5×
of native Julia in Node.js.

Floating-point results are bit-identical to native Julia built for a CPU without FMA
(`-C generic`); natively on FMA hardware, `muladd` fuses, so results differ in the last
bits (and chaotic systems diverge from there). Relaxed SIMD's `relaxed_madd` could give
`muladd` native speed and rounding on most hardware, at the cost of determinism.

## 10. Testing

Differential (`@wtest f(args...)`): native and compiled results compared (values and
types), in a persistent Node.js from `NodeJS_24_jll`, inside one session of patches.
Coverage: numbers and control flow, 128-bit integers, structs/vectors/closures/broadcast/
sort, the image (tables, symbols, cycles, identity), and JuliaC.jl's own test programs
(reshape, dispatch, reductions, concatenations, printing; the untrimmable one must be
rejected). The examples (`examples/lorenz`) solve ODEs with SimpleDiffEq and
OrdinaryDiffEq.
