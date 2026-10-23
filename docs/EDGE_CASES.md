# Edge cases (from WasmTarget.jl)

A checklist of Julia semantics that a Julia → WasmGC compiler has to get right, mined
from WasmTarget.jl (an earlier compiler; paths are relative to its checkout). O =
overlay, C = codegen special case, U = unsupported there, ⚠ = divergence there.
WasmCodegen's own decision follows each item when it differs.

## Integers
- Over-shift: Wasm masks the count, Julia gives 0/sign-fill; i64 count narrowed to i32
  must saturate; negative counts flip direction (calls.jl:316, 394; O interpreter.jl:969).
  → WasmCodegen: compare + select, at the type's width.
- Int8/16 in i32 with dirty high bits (WasmTarget normalized lazily; bugs e2871387d980).
  → WasmCodegen: canonical zero-extended small ints, masked after every op that can set
  high bits; sign-extended only where signedness is observed.
- Checked arithmetic → Tuple{T,Bool}; mul overflow via widening/divide-back
  (calls.jl:652-720).
- div/rem: Wasm traps on /0 and typemin÷-1 (narrow widths silently wrap); Julia throws
  DivideError (calls.jl:241-280).
- Int128: struct {lo,hi}; add/sub/mul/neg/cmp/shifts/clz/ctz/popcnt/bitwise implemented;
  checked ops, div/rem, bswap unsupported (int128.jl). → WasmCodegen: two i64 leaves.
- bitcast/reinterpret: Base.reinterpret inlines padding machinery; O to Core.bitcast for
  same-width primitives (interpreter.jl:781-803).
- Char = left-justified UTF-8 bytes in u32 (not the codepoint); constants must emit the
  raw bits.
- Bool: not_int is eqz; trunc_int(Bool) masks &1.

## Floats
- ⚠ fma_float emitted as mul+add (not single rounding); have_fma false; pow_body uses
  Base.fma_emulated for bit-exactness. → WasmCodegen: fma_float → Base.Math.fma_emulated.
- min/max: f64.min/max differ on NaN/±0; O isless/maximum/minimum/argmax/unique.
- ⚠ `===` on floats as f64.eq (NaN, ±0 wrong). → WasmCodegen: bitwise.
- ⚠ fptosi/fptoui with trapping trunc. → WasmCodegen: trunc_sat.
- Float16 unsupported (arithmetic picked f64 ops). → software fpext/fptrunc.
- rem/mod(Float64): O with exact scaled subtraction; mod(x, ±Inf) differs 1.12/1.13.
- Math.table_unpack indexes NTuple{256} at runtime (O to a Vector constant).
  → WasmCodegen: runtime tuple index on a constant tuple → serialized array.
- wasm-opt --traps-never-happen breaks code that relies on traps as error paths.

## Memory / MemoryRef / Array
- Memory = raw wasm array; MemoryRef = (array, i32 index) never materialized.
- ⚠ memoryrefoffset static (always 1): no nonzero offsets, front mutation reallocates.
  → WasmCodegen: the index is real, offset = index + 1.
- Growth reimplemented by overlays (no capacity). → WasmCodegen: Base's own growth code.
- Bounds: reads past size within capacity return garbage → :boundscheck must be honored.
- jl_alloc_genericmemory: i64→i32 length wrapped without check. → check.
- memmove/memcpy/jl_genericmemory_copyto: pointers traced back to arrays → array.copy
  (fragile; 2-D memmove silently zeroed). → WasmCodegen: overlay unsafe_copyto! on
  MemoryRefs with an array.copy intrinsic; no pointer tracing.
- memset only zero-fill. → overlay fill!/memset with array.fill.
- isbits arrays always "assigned"; reference arrays: null = #undef.
- ⚠ Vector{Union{Nothing,Int64}} stored nothing as 0.
- Packed i8/i16 arrays; UInt8 arrays share String's byte array type.
- Views/SubArray ordinary structs; ReinterpretArray needed overlays.

## Strings / Symbols
- String {classId, idHash, bytes, flags}; Symbol same layout, NOT interned; === on
  String/Symbol compared contents.
- Literal segments: signed LEB length bug for 64-127 bytes.
- jl_string_ptr faked; pointerref/memchr/memhash traced back to the string.
- 1.13 hash(::String) overlaid with FNV → Dict order differs from native.
- IOBuffer/print_to_string unsupported; many string-function overlays.
- Unicode: Latin-1 case conversion; utf8proc tables baked (2.2 MB).

## Structs
- #undef reference fields null; primitive fields need definite initialization.
- Types <:Number/<:AbstractArray that are structs (Dual, SArray, SparseMatrixCSC) needed
  carve-outs. → WasmCodegen: layout from the type's fields, never from its supertype.
- Self-referential types → rec groups.
- Immutable === field by field (ref.eq on reference fields — wrong for immutable refs).
- NTuple runtime index → array.new_fixed + index; heterogeneous → if-chain.
- Union fields / abstract fields → boxed anyref.
- Core.Box typed by join of writes.
- Closures {context, vtable, functionType} via call_ref.

## Unions / boxing
- Numeric unions boxed {classId, value}; earlier collapsing to f64 / i31 truncated.
- ⚠ Union{Nothing, numeric} as bare numeric with nothing = 0.
- isa via DFS classId ranges plus extra ids; typeof(x)===T via ref.eq to a per-type global.
- objectid: lazy counter in the object prefix.

## Exceptions
- One tag (anyref exn, externref trace) + $current_exn global.
- :the_exception / :leave / :pop_exception; rethrow.
- Catchable builtin errors built exactly (DivideError, BoundsError, FieldError, kwerr
  MethodError).
- Always-throwing try body has no :leave; branch-split try regions.

## Dispatch / calls
- Dynamic dispatch via classId + selector table (≤2 varying positions).
- invoke_in_world/invokelatest → static call.
- _apply_iterate only for vectors.
- Concrete-eval disabled → type-level calls stayed dynamic (whitelist fold).
  → WasmCodegen: native concrete-eval (overlay-aware via effects).

## Constants / globals
- Immutable constants dedup'd as const-expr globals; mutable ones one global per object,
  initialized by start functions; GlobalRef reads snapshot host values; cyclic constants
  unsupported; DataType objects populated at start.

## Dict / Set / hash
- O for Dict tuple ctor, delete! (atomic_pointerset), union!; zero-memset no-op in rehash!.

## Recurring failure classes
- Phi/merge with ≥2 live values; loop counters in nested ifs; dead-flag poisoning;
  unlowered ccalls returning silent zeros; 1.12 vs 1.13 drift; Int64 > 2^53 through JSON
  in the test oracle.
