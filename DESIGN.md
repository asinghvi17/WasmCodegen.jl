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
  │  simple code: a local per value; per-type helpers for memory access and boxing
  │  runtime functions (Julia) and host imports added on demand
  ▼
image: serialize the referenced objects; start function completes them
  ▼
raw module (WasmBuilder's validation, and wasm-tools' when installed)
  ▼
wasm-opt -O3 (Binaryen_jll): locals, stack code, inlining, the rest
  ▼
module bytes
```

## 1. The program's world: no overlays, patches

Inference is Julia's own: the same `InferenceParams`/`OptimizationParams` as juliac
(`force_enable_inference`), concrete and semi-concrete evaluation included, over Julia's
own method table, with its own cache owner. The only target-specific fact is
`have_fma = false` (Wasm has no fused multiply-add), folded in `abstract_call_known`.
Inlining is Julia's own too. One optimizer parameter differs: `compilesig_invokes = false`,
so a call targets the method instance of its argument types rather than the signature
native code would be compiled for, which widens arguments of type `Function`, `Type` and
`Vararg` that a method only passes on. A closed world has no dynamic dispatch to fall back
on: JuliaSyntax's parser passes its subparsers as `down::Function`, which juliac's own
verifier rejects, and compiles once they are specialized.

There is no overlay method table, not even an empty one. Stacking one makes the
interpreter overlayed, and inference then taints every call it cannot resolve statically
(`nonoverlayed`), which disables concrete evaluation of everything that may reach one (a
`typejoin` building a vector; `Base.packedsize`, whose `padding` reflects on field types,
so `reinterpret(NTuple{4,UInt8}, x)` compiled its reflection instead of folding it). And
code built on fake native bodies confuses effects (an overlay's native fallback made an
intrinsic look effect-free, and it was deleted). What overlays would do is done instead:

- **juliac's trim patches** (`src/trim/juliac-*.jl`, from JuliaC.jl): the method
  redefinitions juliac applies in its build process (`invokelatest` as a direct call, no
  logger lookups, trim-friendly `show(::Type)`, raised `max_args`, ...);
- **the pseudo-runtime's patches** (`src/trim/wasm-*.jl`): Base and Core methods
  redefined for what Wasm has no C runtime for, written over runtime primitives. IO:
  Core's standard streams write through `Runtime.IO.write_byte` instead of libuv.
  `Base._reinterpret` of isbits values folds the padding reflection at compile time and
  calls `Runtime.reinterpret_bits` (which the code generator compiles to a rearrangement of
  leaves) instead of copying bytes between `Ref`s. Random's bulk generator's vector
  operations (`llvmcall`s on `NTuple{N,VecElement{UInt64}}`) are the same operations on
  each element, so its streams are the native ones;
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

IRStructurizer recovers `IfOp`/`WhileOp`/`LoopOp` regions with block arguments; Wasm
control flow is structured, so the lift is direct:

| Structured op | Wasm |
|---|---|
| `IfOp` with `YieldOp`s | `if` with result locals assigned in each arm |
| `LoopOp` (`ContinueOp`/`BreakOp`) | `block $exit (loop $cont ...)` |
| `WhileOp` (before/`ConditionOp`/after) | `block (loop before (if !cond results br exit) after br loop)` |
| `ReturnNode` | `return` |

Loops are not promoted to counting `ForOp`s (`promote = false`): a `ForOp` has neither the
signedness of the comparison it came from (`ult_int`) nor room for an inclusive bound at
`typemax`, and gains nothing on Wasm. Carried values are assigned in parallel (all values
pushed, then all locals set). Results of control-flow ops are lists of values read by
`getfield(op, i)`.

The structured form threads values through every `if` on the path between a definition
and a merge (a phi of Julia's IR becomes results of each enclosing `if`): JuliaSyntax's
`parse_call_chain` has 1,511 `if`s with 57,977 results. Three rules keep that from turning
into copies, all exact:

- **Aliasing.** A result that each arm yields as the same value, or as undefined, is that
  value: no locals, no copies (Wasm locals live in the whole function, and an undefined
  result is not read). An undefined value is never stored.
- **Destination passing.** A result of a control-flow op that only goes to the yield ending
  its block, to the enclosing `if`'s result, is assigned there directly: a chain of nested
  merges shares one set of locals. (Never to a loop's carries, which the loop reads.)
- **Dead carries.** A loop carry nothing reads has no locals. IRStructurizer's
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
runtime; pointers two leaves, an `i64` virtual address and the object they point into
(section 5).

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

## 5. Pointers: address and owner

Wasm has no addresses. Base takes pointers into memory (`ptr_or_offset`, `pointer(s)`,
`jl_value_ptr` of a `Ref`) to call C (`memmove`, `memset`, ...), for alias checks
(`dataids`), and to read memory as other types (SHA reads its byte buffer as `UInt32`s,
Random writes `UInt64`s into a `Vector{UInt8}`). A `Ptr` is two leaves (`pointers.jl`):

- a **virtual address** (`i64`): each object gets a range from its identity hash shifted by
  32 bits, plus the byte offset, so comparisons and differences behave as natively; integer
  operations on pointers are operations on their addresses;
- its **owner**, the object it points into (a Memory, a String, a `Ref`), or null for a
  pointer made from an integer, which cannot be dereferenced.

Pointer arithmetic moves the address and keeps the owner, and both cross calls with the
pointer, as any value's leaves do. Memory is addressed by bytes as Julia lays it out, so a
pointer may reinterpret it.

Within a function, a pointer also carries its **origin** when it is known statically: the
array of its owner, the byte offset into it, and the type of its elements. A load, store,
`memmove` or `memset` through pointers with origins compiles to array accesses
(`array.get`/`set`, `array.copy`, `array.fill`): of whole elements when aligned to them
(checked at run time, as Julia allows any alignment), else of the bytes of the elements
holding them. Without an origin (a pointer that crossed a call), the access goes byte by
byte through two run-time helpers, `jl_ptr_load_byte(address, owner)` and
`jl_ptr_store_byte(address, owner, byte)`, generated once the module's types are known:
they find the byte from the owner's type id: of a memory whose elements are stored as
laid out, of a memory of widened or padded isbits elements (by the leaves of an element),
of a string, or of the isbits fields of a mutable object. `memmove` and `memset` without
origins are byte loops in the runtime (`Runtime.ptr_memmove`/`ptr_memset`). An owner whose
bytes are not addressable (a memory of references) traps.

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
- A `Ptr` constant is its address without owner (an address of the build process).
- A symbol carries its hash, as Julia's runtime computed it, so that dictionaries with
  symbol keys built at compile time are found at run time.
- Not serializable (an error naming the object): tasks, modules, methods.

## 7. Functions, calls, intrinsics

One Wasm function per CodeInstance; parameters and results are the leaves of the
arguments (the function object too, for closures; varargs packed in a tuple) and of the
return type. `:invoke` calls it, converting representations (boxing for abstract
parameters). Builtins (`getfield`, `setfield!`, `===` (bitwise on floats, by content for
immutables), `isa` (type ids, a generated predicate per abstract type), `tuple`,
`ifelse`, `memoryref*`, `_apply_iterate` into tuples, ...) and intrinsics are emitted
inline, with Julia's semantics where Wasm's differ: over-shifts, saturating float→int,
checked arithmetic, `fpiseq`, IEEE `min`/`max`, division traps.

Operations whose code grows with the value they move are **outlined**: a helper function
per operation and type, called where they are used (`outline.jl`): `memoryrefget`,
`memoryrefset!`, `memoryrefnew`, `memoryref_isassigned`, `memorynew`, boxing and unboxing.
A helper's body is the operation's inline emission, run in the helper's own context, so
there is one implementation; Binaryen inlines the helpers where it pays, and keeps others
shared (10% smaller modules for the parser).

## 8. The runtime

- **Runtime functions** (`src/runtime/`, module `WasmCodegen.Runtime`): Julia code the
  code generator calls for what Wasm lacks, compiled into the module on demand
  (`runtime_function!` extends the closed world): 128-bit integer arithmetic on `UInt64`
  pairs (multiplication by 32-bit halves, shift-subtract division); `fma` is Base's
  `fma_emulated`.
- **C library calls implemented in Julia** (`RUNTIME_CCALLS`), checked against the native
  libraries: Unicode properties (`utf8proc_category`, `jl_id_char`, `jl_id_start_char`:
  tables of runs computed from the native libraries when WasmCodegen is compiled, exact
  on every code point; `utf8proc_grapheme_break_stateful`: utf8proc's rules over its
  classes); `strtod`/`strtof` (the extent of the number as C finds it, the value from
  Parsers.jl, which is correctly rounded without C or big floats) and `errno`;
  `memmove`/`memset`/`memcmp`/`memchr` through pointers without origins.
- **Hashes as the C runtime computes them**, so that dictionaries built at compile time are
  found at run time: `objectid` of symbols (their hash: MurmurHash3 of the name, mixed;
  symbols in the image carry it, computed natively) and of isbits values of 1, 2, 4 or 8
  bytes (`immut_id_`: the bits' hash and the type's). Strings and symbols are `===` by
  their bytes, so symbols made at run time need no interning.
- **Primitives**: runtime functions whose calls the code generator compiles to host
  imports (module `julia`): `write_byte(fd, byte)`, `entropy()` (the seed of the task's
  random number generator).
- **The pseudo-runtime's patches** (section 1): Base/Core methods over the primitives
  (IO for `Core.stdout`/`Core.stderr`).
- **The host**: a loader instantiating the module with the `julia` imports (the test
  runner's is in `test/runner.mjs`): it buffers bytes per descriptor and decodes them as
  UTF-8.

Next: `IdDict` (the C runtime's identity hash table, also behind task-local storage and so
`Random.seed!` of the global generator), exceptions with `try_table`, time; a WASI-style
host interface.

## 9. Output, performance

Exports are the entry points under their names, with their leaves as parameters and
results (`i64` is a JavaScript BigInt).

The code generator emits simple code and `compile` optimizes it with `wasm-opt -O3`
(`Config(optimize=...)`; the features are listed explicitly: `-all` enables proposals V8
does not ship). Allocating locals, putting values on the operand stack and inlining small
helpers are Binaryen's job, which it does far better than a code generator's own passes
would (JuliaSyntax's parser: 147,000 locals to 3,500). A raw module is not meant to run:
its large functions have frames of thousands of locals, which overflow the stack of a
recursive parser. What the code generator does avoid is code `wasm-opt` would have to
remove at a cost: without the rules of section 3, `wasm-opt` takes 13 times longer on the
parser (683 s against 53 s) for a worse module, and destination passing halved it again
(23 s). Most of its time is `simplify-locals` on the largest functions.

For the parser, a compile takes about 23 s in `wasm-opt`, 8 s in IRStructurizer, 3 s in
juliac's verifier and 2 s in the code generator (after Julia's inference, cached across
compilations). OrdinaryDiffEq's Tsit5 on the Lorenz system runs within about 1.5× of native
Julia in Node.js; a ModelingToolkit model and the parser run at about native speed.

Floating-point results are bit-identical to native Julia built for a CPU without FMA
(`-C generic`); natively on FMA hardware, `muladd` fuses, so results differ in the last
bits (and chaotic systems diverge from there). Relaxed SIMD's `relaxed_madd` could give
`muladd` native speed and rounding on most hardware, at the cost of determinism.

## 10. Testing

Differential (`@wtest f(args...)`): native and compiled results compared (values and
types), in a persistent Node.js from `NodeJS_24_jll`, inside one session of patches.
Coverage: numbers and control flow, 128-bit integers, pointers, identity, globals,
structs/vectors/closures/broadcast/sort, dictionaries and sets, Random (the native
streams), the image (tables, symbols, cycles, identity), and JuliaC.jl's own test programs
(reshape, dispatch, reductions, concatenations, printing; the untrimmable one must be
rejected). The tests run the optimized modules. The examples: `examples/lorenz`
(OrdinaryDiffEq), `examples/mtk` (a ModelingToolkit model), `examples/juliasyntax` (Julia's
parser, compared with native JuliaSyntax node for node on Base's sources), each with a page.
