# WasmCodegen.jl design

WasmCodegen compiles Julia programs to WebAssembly with the GC proposal (WasmGC), the
way `juliac --trim` compiles them to native code: from entry points, it collects the
closed world of code they can run, compiles it, and serializes the Julia objects that code
refers to into the binary, so the module starts with the heap the program needs. No
Julia runtime is linked: what the runtime does natively (allocation, GC, object layout,
type tags) is done by WasmGC and by code generated here.

It is a fresh design: WasmTarget.jl is a reference for the semantic edge cases it handled,
not for its architecture. It follows JuliaCodegen.jl (Julia's code generator written in
Julia) in how values are represented and how the IR is walked, and SynchJulia.jl and
cuTile.jl in how it gets IR (an overlay interpreter) and structures control flow
(IRStructurizer.jl).

```
entry points (f, argtypes)                       ── like juliac's entry points
  │  collect: CC.compile! under WasmInterpreter   ── juliac's typeinf_ext_toplevel
  │  (overlay method table, native inference)
  ▼
closed world: (CodeInstance, CodeInfo) pairs     ── trim-verified (warn or error)
  │  per function: CodeInfo → IRCode → prepare (EH policy, ...) → StructuredIRCode
  ▼
structured IR (IfOp / ForOp / WhileOp / LoopOp)  ── IRStructurizer.jl
  │  emit: walk, lower statements                ── WasmBuilder.jl (validating builder)
  ▼
WasmGC functions + types
  │  image: serialize the referenced objects     ── like juliac's image (staticdata)
  ▼
module bytes (+ wasm-opt) + JS loader
```

## 1. Collecting the closed world

`WasmInterpreter <: AbstractInterpreter` is the native interpreter with:

- a method table stacking the overlay table `WASM_MT` over Julia's
  (`CompilerCaching.StackedMethodTable`). Overlays replace methods whose native
  implementation cannot be compiled (pointer arithmetic, `ccall`s into libjulia or libc)
  with implementations in terms of Wasm intrinsics (section 6);
- native inference and optimization parameters (`force_enable_inference=true`, as juliac).
  In particular concrete evaluation stays enabled: overlay-tainted calls are excluded by
  the effects system (`nonoverlayed`). Semi-concrete evaluation is disabled
  (JuliaLang/julia#47349), as SynchJulia does. WasmTarget disabled concrete evaluation
  entirely, which left keyword-argument machinery (`Core.apply_type(Pairs, ...)`) dynamic
  in code that is trim-clean natively;
- its own cache owner, a `codegen` cache of uncompressed `CodeInfo`s, and
  `may_discard_trees = false`;
- `have_fma` folded to `false` (Wasm has no fused multiply-add).

The closed world is collected exactly as `Compiler.typeinf_ext_toplevel` does for juliac:
a `CompilationQueue` seeded with the entry `MethodInstance`s, drained by `CC.compile!`
into `(CodeInstance, CodeInfo)` pairs, then `verify_typeinf_trim` (configurable: error,
warn, off). `:invoke` targets missing from the set (error paths whose callees inference
did not keep) are re-collected to a fixpoint.

What cannot be compiled is decided by the code generator, not by a whitelist: a function
using an unsupported construct is an error naming the construct, the function and the
inlining stack, or, under a configuration policy, compiles to a trap.

Dynamic dispatch is not supported in the first version (the trim-safe subset). Calls
whose result type is `Union{}` (error paths) compile to traps.

## 2. Structured IR

Each `CodeInfo` is inflated to `IRCode` and structured by IRStructurizer
(`StructuredIRCode(ir)`), which recovers `IfOp`/`ForOp`/`WhileOp`/`LoopOp` regions with
block arguments for loop-carried values. Wasm control flow is structured (`block`,
`loop`, `if`, `br` to an enclosing label), so the lift is direct:

| Structured op | Wasm |
|---|---|
| `IfOp` with `YieldOp`s | `if` with result locals assigned in each arm |
| `LoopOp` (`ContinueOp`/`BreakOp`) | `block $exit (loop $cont ...)`: continue = assign carries, `br $cont`; break = assign results, `br $exit` |
| `ForOp` (iv, `slt` bound, step) | `block (loop (br_if exit (not (lt_s iv upper))) body iv+=step br)` |
| `WhileOp` (before/`ConditionOp`/after) | `block (loop before (if cond then after-with-args, br loop; else results))` |
| `ReturnNode` | `return` |

Values of control-flow ops (results of if/loops) are tuple-typed SSA values read through
`getfield(%op, i)`: they are kept as lists of values (no tuple is built).

Exception handling: IRStructurizer rejects `EnterNode`. The first version compiles
`throw` to a trap, so handlers are dead; a preparation pass removes the `EnterNode`s (their
handler edges), `:leave` and `:pop_exception`, before structurizing. Real exceptions (a
Wasm tag carrying the Julia exception object, `try_table` regions) need structured
try regions in IRStructurizer (being designed separately).

## 3. Values

Like JuliaCodegen (and Julia's own code generator), a value has a representation decided
by its type:

- **ghost**: singleton and zero-size types (`nothing`, functions without captures, unique
  `Type{T}`): no Wasm value.
- **inline**: concrete immutable types stored inline natively (primitives, tuples,
  immutable structs, closures): a flat list of Wasm values, its *leaves*, the
  concatenation of the leaves of its fields. `Float64` is one `f64`; `SVector{3,Float64}`
  is three `f64`s; `Tuple{Int,Vector{Float64}}` is an `i64` and a reference. Inline values
  are never allocated: `getfield` with a constant index selects leaves, `new` gathers
  them, calls pass them as several parameters and return them as several results
  (multi-value). This is native code's SROA, by construction.
- **boxed**: everything else (mutable types, abstract types, unions, `Memory`, `String`):
  one reference.

Primitive types: `Bool`, 8/16/32-bit integers and `Char` (its raw bits) are `i32`;
64-bit integers `i64`; `Float32`/`Float64` `f32`/`f64`; `Float16` its bits in an `i32`;
`Int128`/`UInt128` two `i64`s (low, high). Pointers are `i64`, opaque (they cannot be
dereferenced; code that does is overlaid or rejected).

Inline unions (Julia's `UnionVal`: a selector and a payload) are boxed in the first
version.

### Objects

Every boxed object that may be stored where the static type is abstract is a subtype of

```
$JlValue = (sub (struct (field $typeid i32) (field $hash (mut i32))))
```

The type id is a small integer per Julia concrete type (a table maps ids to serialized
`DataType`s for `typeof`); `hash` is the identity hash (`objectid`), assigned lazily.

- A mutable struct `T` is `(sub $JlValue (struct i32 (mut i32) (mut leaf)...))`: its
  fields' leaves, flattened, as in Julia's layout (an inline immutable field is stored
  inline). An undefined reference field is null; `isdefined` tests it.
- An immutable inline value stored where the type is abstract is boxed in
  `$Box{T}`, the same layout with immutable fields.
- A ghost value stored where the type is abstract is its singleton object (one global per
  type), as `jl_nothing` natively.
- `Memory{T}` is a Wasm array, not a `$JlValue` (see below), boxed in a wrapper
  `$MemBox{T}` when stored where the type is abstract (its `===` compares the arrays).
- `String` is an array of `i8`, the same Wasm type as `Memory{UInt8}`, so the conversions
  between them (`jl_string_to_genericmemory`, `jl_genericmemory_to_string`) share bytes
  like native code. Boxed like `Memory`.
- `Symbol`s are `$JlValue` objects with their name, one global per symbol (interned at
  compile time).

All Wasm types of the module are in one recursion group, so they are nominal: each
Julia type has its own Wasm type even when layouts agree, and `ref.test` distinguishes
them.

References in locals, parameters and fields are nullable (`ref null`): null is the
undefined value, and nullable locals need no initialization analysis. `wasm-opt` refines
them.

### Memory, MemoryRef, Array

`Memory{T}` is a Wasm array whose elements store `T`:

- primitive `T`: its numeric type, packed (`i8`, `i16`) for small integers and `Bool`;
- inline `T` whose leaves have one numeric type (`SVector{3,Float64}`, `ComplexF64`,
  `NTuple{4,UInt8}`): that type, `k` array elements per Julia element (stride `k`), as
  Julia lays them out;
- other inline `T`: references to `$Box{T}`;
- boxed `T`: references (`(ref null $JlValue)` for abstract `T`); null is `#undef`;
- ghost `T`: an `i8` array whose length is the length.

`MemoryRef{T}` is inline: the array and an `i32` element index (`ptr_or_offset` is not
represented). `memoryrefnew`, `memoryrefget`, `memoryrefset!`, `memoryref_isassigned`,
`memoryrefoffset` are compiled from that (with bounds checks when asked). `Array{T,N}` is
then an ordinary mutable struct (`ref::MemoryRef{T}`, `size::NTuple{N,Int}`), so all of
Base's array code compiles from its Julia implementation; only the allocation
(`jl_alloc_genericmemory`, or `memorynew` on 1.13) and bulk operations (`memmove`,
`memset`, `jl_genericmemory_copyto`) are intrinsics.

## 4. Functions and calls

One Wasm function per `CodeInstance`. Its parameters are the leaves of its non-ghost
arguments (the function object too, for closures); varargs methods take their varargs as
one tuple (as `IRCode` has them). Its results are the leaves of its return type; a
function returning `Union{}` has none and calls to it are followed by `unreachable`.

`:invoke` calls the function of the target `CodeInstance` (or `MethodInstance`), with
the arguments converted to the callee's argument types (boxing an inline value for an
abstract parameter). Builtins (`getfield`, `setfield!`, `===`, `isa`, `typeof`,
`tuple`, `ifelse`, `memoryref*`, ...) and intrinsics (`add_int`, `fptosi`, ...) are
emitted inline, from tables, with Julia's semantics where Wasm's differ:

- shifts: Julia's `shl_int`/`lshr_int`/`ashr_int` give 0 (or the sign) for counts beyond
  the width; Wasm masks the count: emit the comparison and a `select`;
- `fptosi`/`fptoui`: use the saturating conversions (`trunc_sat`) where Julia's are
  undefined, never the trapping ones;
- `fma_float`: no Wasm instruction; a software fma (overlay, exact);
- `min`/`max` of floats are Julia code (`f64.min` differs on signed zero and NaN);
- checked arithmetic (`checked_sadd_int` ...) returns the value and the overflow flag;
- integer division traps on zero in Wasm; Julia's `div` checks before calling the
  intrinsic, so the trap is unreachable in correct code.

## 5. The image: serializing objects

Code refers to objects: literals in the IR (`QuoteNode`s, constant globals), the values of
global variables, and every object reachable from those. Natively they live in the
image; here they are serialized into the module, as globals whose initializers build
them. This is what makes the compiler work like juliac: a program can build data at
compile time (an `ODEProblem`, a lookup table, a model assembled by ModelingToolkit) and
refer to it, and the module contains that data, not the code that built it.

- An inline constant is emitted as instructions (its leaves; references inside it are
  `global.get`s of serialized objects).
- A boxed constant is one immutable global of its Wasm type, initialized by a constant
  expression: `struct.new` with its fields (constants, or `global.get` of objects
  serialized before it), `array.new_fixed` for small arrays.
- Identity is preserved: an `IdDict` maps objects to globals, so an object referenced from
  several places is one object, and `===` holds as natively.
- Cycles (only possible through mutable objects) and forward references: a reference
  field whose object is not yet defined is initialized to null, and the module's start
  function sets it (`struct.set`/`array.set`) once every global exists. Objects are
  emitted in depth-first postorder so that this is rare.
- Large arrays of numbers are `array.new_default` in the initializer (a constant
  expression) and filled by the start function from a passive data segment
  (`array.init_data`); large arrays of references are filled by the start function.
- Global variables (non-constant bindings) are mutable Wasm globals (one per leaf of
  their declared type), initialized with their value at compile time.
- `DataType`s used as values are serialized as `$DataType` objects (name, type id,
  parameters as needed); `Module`s, `Method`s, `Task`s, non-null pointers and other runtime
  objects cannot be serialized: an error names the path from the root to the object.

The type ids are fixed when the module is complete; `isa` against an abstract type tests
the set of concrete types of the closed world that are its subtypes (a generated
predicate per abstract type).

## 6. Overlays and intrinsics

Overlays (`@overlay WASM_MT`) replace Base methods whose implementation depends on
pointers or the C runtime: `unsafe_copyto!` on `MemoryRef`s (memmove), `fill!` on `Memory`
(memset), the string primitives that use `pointer(s)` (`codeunit`, `ncodeunits`,
`String(::Memory)` ...), `objectid`, `fma`, printing (to an imported host function).

They are written in Julia against a small set of intrinsic functions
(`WasmCodegen.Intrinsics`, `@noinline` functions without a native implementation) that the
code generator recognizes in `:invoke`s and emits as Wasm instructions (`array.copy`,
`array.fill`, `array.len`, host calls).

## 7. Output and the host

The module exports the entry points under their names, with the leaves of their
arguments and results as parameters and results (`i64` is a JavaScript BigInt). A
generated JavaScript loader instantiates the module with the host functions it imports
(printing, the trap reporter) and the `js-string` builtins when strings cross the
boundary. Passing Julia objects (vectors, structs) across the boundary uses generated
accessor exports.

Optimization is Binaryen's `wasm-opt` with the GC-aware passes (`-O3` plus type
refinement, `--gufa`, heap-to-local for allocations that do not escape).

## 8. Testing

Differential, as JuliaCodegen's `@cgtest`: `@wtest f(args...)` runs `f` natively and
compiled (in a persistent Node.js process) and compares results and argument mutations.
`WasmBuilder`'s validating builder checks every function as it is generated, and
`wasm-tools validate` checks every module in the tests.

## 9. First milestones

1. Numbers and control flow; calls between functions.
2. Structs, tuples, closures (inline and mutable).
3. `Memory`/`Array`: `Vector{Float64}` code from Base (`push!`, `sum`, broadcasting).
4. The image: constants and global variables, mutable objects, cycles.
5. Boxing, unions, `isa`/`typeof`, `===`.
6. An ODE: SimpleDiffEq's fixed-step solvers, then OrdinaryDiffEq's `Tsit5` (out-of-place
   `SVector` and in-place `Vector` problems), with a problem built at compile time.
