# Foreign calls: the few calls into Julia's C runtime that Base's code makes for things
# Wasm does natively (allocation, strings as bytes, copies of memory). Others are
# unsupported; calls into C libraries need runtime functions or host imports.

function foreigncall_name(@nospecialize(x))
    x isa QuoteNode && (x = x.value)
    x isa Symbol && return x
    x isa Tuple && return x[1] isa Symbol ? x[1] : nothing
    if x isa Expr && x.head === :call && length(x.args) >= 2
        return foreigncall_name(x.args[2])
    elseif x isa Expr && x.head === :tuple && !isempty(x.args)
        # (name, library) (Julia 1.13)
        return foreigncall_name(x.args[1])
    end
    return nothing
end

function emit_foreigncall!(fc::FnCtx, ex::Expr, @nospecialize(typ))
    name = foreigncall_name(ex.args[1])
    nargs = length(ex.args[3]::Core.SimpleVector)
    args = Any[operand(fc, a) for a in ex.args[6:5+nargs]]
    if name === :jl_alloc_genericmemory
        M = args[1]::CGVal
        isconstant(M) || unsupported("allocating a Memory of a type not known at compile time")
        return outlined_memorynew!(fc, constant_value(M), args[2])
    elseif name === :jl_alloc_string
        n = convert_repr(fc, args[1], Int)
        push_val!(fc, n)
        emit!(fc.b, :i32_wrap_i64)
        emit!(fc.b, :array_new_default, array_type!(fc.cgm.types, I8))
        return new_bytes_object!(fc, String)
    elseif name === :jl_string_to_genericmemory
        # a Memory sharing the bytes of the string
        s = args[1]::CGVal
        push_val!(fc, s)
        emit!(fc.b, :struct_get, layout(fc, String).wtype, DATA_FIELD)
        return new_memory_object!(fc, Memory{UInt8})
    elseif name === :jl_genericmemory_to_string
        mem, n = args[1]::CGVal, convert_repr(fc, args[2], Int)
        arr = array_type!(fc.cgm.types, I8)
        dst = new_local!(fc, RefType(arr, true))
        push_val!(fc, n)
        emit!(fc.b, :i32_wrap_i64)
        emit!(fc.b, :array_new_default, arr)
        emit!(fc.b, :local_set, dst)
        emit!(fc.b, :local_get, dst); emit!(fc.b, :i32_const, 0)
        push_memory_array!(fc, mem); emit!(fc.b, :i32_const, 0)
        push_val!(fc, n); emit!(fc.b, :i32_wrap_i64)
        emit!(fc.b, :array_copy, arr, arr)
        emit!(fc.b, :local_get, dst)
        return new_bytes_object!(fc, String)
    elseif name === :jl_symbol_n
        # not interned: symbols are === by their bytes (see `egal_bytes!`)
        return bytes_from_ptr!(fc, args[1], args[2], Symbol)
    elseif name === :jl_pchar_to_string
        return bytes_from_ptr!(fc, args[1], args[2], String)
    elseif name === :jl_object_id
        return emit_objectid!(fc, args[1]::CGVal)
    elseif name === :memchr
        return call_runtime!(fc, Runtime.ptr_memchr, CGVal[byte_ptr(args[1]), convert_repr(fc, args[2], Int32),
                                                            convert_repr(fc, args[3], UInt)])
    elseif name === :memcmp
        return call_runtime!(fc, Runtime.ptr_memcmp, CGVal[byte_ptr(args[1]), byte_ptr(args[2]),
                                                            convert_repr(fc, args[3], UInt)])
    elseif name === :memmove || name === :memcpy
        return emit_memmove!(fc, args[1], args[2], args[3], true)
    elseif name === :jl_genericmemory_copyto
        # (dest memory, dest pointer, src memory, src pointer, n elements)
        emit_memmove!(fc, args[2], args[4], args[5], false)
        return ghost(Nothing, nothing)
    elseif name === :memset
        return emit_memset!(fc, args[1], args[2], args[3])
    elseif name === :jl_get_current_task
        # one task: the module's (its RNG state seeded by the host at start)
        emit!(fc.b, :global_get, current_task_global!(fc.cgm))
        return pop_val!(fc, Task)
    elseif name === :jl_genericmemory_owner
        # a Memory owns itself here (none shares a String's storage as its owner)
        return convert_repr(fc, args[1]::CGVal, typ)
    elseif name === :jl_string_ptr
        return string_ptr!(fc, args[1]::CGVal, typ)
    elseif name === :jl_value_ptr
        return object_ptr!(fc, args[1]::CGVal, typ)
    elseif (r = runtime_ccall(name)) !== nothing
        return emit_runtime_ccall!(fc, r, args, typ)
    elseif name === :jl_get_world_counter || name === :jl_get_tls_world_age
        # the world the code was compiled in: there is one
        return const_value(fc, convert(typ, fc.cgm.world.world))
    elseif typ === Union{}
        unreachable!(fc.b)
        return bottom()
    end
    unsupported("the foreign call ", something(name, ex.args[1]))
end

"""
    emit_objectid!(fc, x) -> CGVal

`objectid(x)` as Julia's C runtime computes it, where it does not depend on addresses: of a
symbol, its hash; of an isbits value without padding of 1, 2, 4 or 8 bytes, the hash of its
bits mixed with its type's hash (`immut_id_`); of a singleton, from its type's hash. Hashes
of `Dict`s built at compile time depend on these values.
"""
function emit_objectid!(fc::FnCtx, x::CGVal)
    T = x.typ
    if isconstant(x)
        v = constant_value(x)
        (v isa Symbol || isbits(v)) && return const_value(fc, objectid(v))
    end
    if T === Symbol
        push_val!(fc, x)
        emit!(fc.b, :struct_get, layout(fc, Symbol).wtype, SYMBOL_HASH_FIELD)
        return pop_val!(fc, UInt64)
    end
    (T isa DataType && isbitstype(T)) || unsupported("objectid of a value of type ", T)
    h = UInt64(reinterpret(UInt32, getfield(T, :hash)))
    sz = sizeof(T)
    sz == 0 && return const_value(fc, ~h)
    I = sz == 1 ? Int8 : sz == 2 ? Int16 : sz == 4 ? Int32 : sz == 8 ? UInt64 : nothing
    (I !== nothing && !Base.datatype_haspadding(T) &&
     (isprimitivetype(T) || (Base.datatype_isbitsegal(T) && Base.datatype_pointerfree(T)))) ||
        unsupported("objectid of a value of type ", T)
    bits = emit_reinterpret_bits!(fc, I, x, T)
    r = call_runtime!(fc, Runtime.bits_hash, CGVal[bits])
    push_val!(fc, r)
    emit!(fc.b, :i64_const, reinterpret(Int64, h))
    emit!(fc.b, :i64_xor)
    return pop_val!(fc, UInt64)
end

"A `String` or `Symbol` (`T`) of a copy of the `n` bytes at the pointer `p`."
function bytes_from_ptr!(fc::FnCtx, p::CGVal, n::CGVal, @nospecialize(T))
    n = convert_repr(fc, n, Int)
    arr = array_type!(fc.cgm.types, I8)
    push_val!(fc, n); emit!(fc.b, :i32_wrap_i64)
    emit!(fc.b, :array_new_default, arr)
    s = new_bytes_object!(fc, String)
    emit_memmove!(fc, string_ptr!(fc, s, Ptr{UInt8}), p, n, true)
    T === String && return s
    h = call_runtime!(fc, Runtime.symbol_hash, CGVal[s])
    push_val!(fc, s); emit!(fc.b, :struct_get, layout(fc, String).wtype, DATA_FIELD)
    return new_bytes_object!(fc, T, h)
end

"""
    new_bytes_object!(fc, T[, hash]) -> CGVal

The `String` (or `Symbol`, with its `hash`, a UInt64) object of type `T` of the bytes on
the stack.
"""
function new_bytes_object!(fc::FnCtx, @nospecialize(T), hash::Union{Nothing,CGVal}=nothing)
    ts = fc.cgm.types
    arr = new_local!(fc, RefType(array_type!(ts, I8), true))
    emit!(fc.b, :local_set, arr)
    emit!(fc.b, :i32_const, typeid!(ts, T))
    emit!(fc.b, :i32_const, 0)
    emit!(fc.b, :local_get, arr)
    T === Symbol && push_val!(fc, hash::CGVal)
    emit!(fc.b, :struct_new, bytes_object_type!(ts, T))
    return pop_val!(fc, T)
end

# the origin of the pointer `p` into the array of a memory, or nothing
function array_origin(p::CGVal)
    o = p.origin
    return o === nothing || is_object_origin(o) ? nothing : o
end

# push the index of the array element the origin `o` points to, or the number of array
# elements of `n` bytes (`count`)
function push_array_index!(fc::FnCtx, o::PtrOrigin, n::Union{Nothing,CGVal}=nothing; elements::Bool=false)
    ml = memory_layout(fc.cgm.types, o.eltype)
    if n === nothing
        push_leaf!(fc, o.index)
    else
        push_val!(fc, n)
        layout(fc, n.typ).leaves[1].type === I64 && emit!(fc.b, :i32_wrap_i64)
    end
    if elements
        ml.stride != 1 && (emit!(fc.b, :i32_const, ml.stride); emit!(fc.b, :i32_mul))
    elseif byte_addressable(fc, o.eltype)
        s = storage_size(fc, o.eltype)
        s != 1 && (emit!(fc.b, :i32_const, s); emit!(fc.b, :i32_div_u))
    else
        u = elem_unit(o.eltype)
        u != 1 && (emit!(fc.b, :i32_const, u); emit!(fc.b, :i32_div_u))
        ml.stride != 1 && (emit!(fc.b, :i32_const, ml.stride); emit!(fc.b, :i32_mul))
    end
end

# push whether the byte offsets of the origins and the length `n` are multiples of the
# storage size `s` of their arrays' elements (an i32)
function push_aligned!(fc::FnCtx, origins, n::CGVal, s::Int)
    for (k, o) in enumerate(origins)
        push_leaf!(fc, o.index)
        k > 1 && emit!(fc.b, :i32_or)
    end
    push_val!(fc, n)
    layout(fc, n.typ).leaves[1].type === I64 && emit!(fc.b, :i32_wrap_i64)
    emit!(fc.b, :i32_or)
    emit!(fc.b, :i32_const, s - 1); emit!(fc.b, :i32_and)
    emit!(fc.b, :i32_eqz)
end

byte_ptr(p::CGVal) = CGVal(Ptr{UInt8}, Inline, p.leaves)

"""
    emit_memmove!(fc, dst, src, n, bytes) -> CGVal

`memmove` (or `jl_genericmemory_copyto`) of `n` bytes (or elements) from `src` to `dst`:
an `array.copy` between the arrays they point into, if known, of one type, and aligned to
their elements, else a copy byte by byte (`Runtime.ptr_memmove`).
"""
function emit_memmove!(fc::FnCtx, dst, src, n, bytes::Bool)
    dst, src, n = dst::CGVal, src::CGVal, n::CGVal
    od, os = array_origin(dst), array_origin(src)
    ts = fc.cgm.types
    if od !== nothing && os !== nothing
        md, ms = memory_layout(ts, od.eltype), memory_layout(ts, os.eltype)
        ba = byte_addressable(fc, od.eltype) && byte_addressable(fc, os.eltype)
        if md.array == ms.array && (od.eltype === os.eltype || ba)
            # bytes of arrays of bytes, or whole elements (of elements not stored as bytes,
            # pointers to whole elements)
            s = bytes && ba ? storage_size(fc, od.eltype) : 1
            if s > 1
                push_aligned!(fc, (od, os), n, s)
                if!(fc.b)
            end
            push_leaf!(fc, od.array); push_array_index!(fc, od)
            push_leaf!(fc, os.array); push_array_index!(fc, os)
            push_array_index!(fc, od, n; elements=!bytes)
            emit!(fc.b, :array_copy, md.array, md.array)
            if s > 1
                else!(fc.b)
                call_runtime!(fc, Runtime.ptr_memmove, CGVal[byte_ptr(dst), byte_ptr(src), convert_repr(fc, n, UInt)])
                end!(fc.b)
            end
            return bytes ? dst : ghost(Nothing, nothing)
        end
    end
    bytes || unsupported("copying elements between memories not known at compile time")
    call_runtime!(fc, Runtime.ptr_memmove, CGVal[byte_ptr(dst), byte_ptr(src), convert_repr(fc, n, UInt)])
    return dst
end

"""
    emit_memset!(fc, p, val, n) -> CGVal

`memset` of `n` bytes at `p` to the byte `val`: an `array.fill` of the array it points
into (of bytes, or of zeros aligned to its elements), else byte by byte
(`Runtime.ptr_memset`).
"""
function emit_memset!(fc::FnCtx, p, val, n)
    p, val, n = p::CGVal, val::CGVal, n::CGVal
    o = array_origin(p)
    if o !== nothing
        ml = memory_layout(fc.cgm.types, o.eltype)
        bytewise = ml.storage === I8 && ml.stride == 1
        if bytewise || (isconstant(val) && iszero(constant_value(val)))
            s = !bytewise && byte_addressable(fc, o.eltype) ? storage_size(fc, o.eltype) : 1
            if s > 1
                push_aligned!(fc, (o,), n, s)
                if!(fc.b)
            end
            push_leaf!(fc, o.array); push_array_index!(fc, o)
            if bytewise
                push_val!(fc, val)
                layout(fc, val.typ).leaves[1].type === I64 && emit!(fc.b, :i32_wrap_i64)
                emit!(fc.b, :i32_const, 0xff); emit!(fc.b, :i32_and)
            else
                st = ml.storage
                push_default!(fc, st isa PackedType ? I32 : st)
            end
            push_array_index!(fc, o, n)
            emit!(fc.b, :array_fill, ml.array)
            if s > 1
                else!(fc.b)
                emit_memset_bytes!(fc, p, val, n)
                end!(fc.b)
            end
            return p
        end
    end
    emit_memset_bytes!(fc, p, val, n)
    return p
end

function emit_memset_bytes!(fc::FnCtx, p::CGVal, val::CGVal, n::CGVal)
    push_val!(fc, val)
    layout(fc, val.typ).leaves[1].type === I64 && emit!(fc.b, :i32_wrap_i64)
    emit!(fc.b, :i32_const, 0xff); emit!(fc.b, :i32_and)
    b = pop_val!(fc, UInt8)
    call_runtime!(fc, Runtime.ptr_memset, CGVal[byte_ptr(p), b, convert_repr(fc, n, UInt)])
end

## C library calls implemented by the runtime

"""
    RuntimeCcall(f, args)

A C function implemented by the runtime function `f`. `args` says how each argument of the
C call becomes an argument of `f`: `:val` (as it is), `:ref` (a pointer to a scalar, as
Fortran passes them: the scalar), `:array` (a pointer into an array: a `MemoryRef`),
`:skip` (dropped, e.g. the hidden lengths of Fortran strings).
"""
struct RuntimeCcall
    f::Any
    args::Vector{Symbol}
end

const RUNTIME_CCALLS = Dict{Symbol,RuntimeCcall}(
    # Unicode properties (libutf8proc, libjulia): tables of the native libraries
    :utf8proc_category => RuntimeCcall(Runtime.UnicodeData.category, [:val]),
    :jl_id_char => RuntimeCcall(Runtime.UnicodeData.id_char, [:val]),
    :jl_id_start_char => RuntimeCcall(Runtime.UnicodeData.id_start_char, [:val]),
    :utf8proc_grapheme_break_stateful =>
        RuntimeCcall(Runtime.UnicodeData.grapheme_break_stateful, [:val, :val, :val]),
    # the C library's float parsing and errno
    :jl_strtod_c => RuntimeCcall(Runtime.Floats.strtod, [:val, :val]),
    :jl_strtof_c => RuntimeCcall(Runtime.Floats.strtof, [:val, :val]),
    :jl_set_errno => RuntimeCcall(Runtime.Floats.set_errno, [:val]),
    :jl_errno => RuntimeCcall(Runtime.Floats.get_errno, Symbol[]),
)

runtime_ccall(name) = name === nothing ? nothing : get(RUNTIME_CCALLS, name, nothing)

function emit_runtime_ccall!(fc::FnCtx, r::RuntimeCcall, args::Vector{Any}, @nospecialize(typ))
    length(args) == length(r.args) ||
        unsupported("a call of ", r.f, " with ", length(args), " arguments")
    vals = CGVal[]
    for (a, kind) in zip(args, r.args)
        a = a::CGVal
        if kind === :val
            push!(vals, a)
        elseif kind === :ref
            push!(vals, ptr_load!(fc, a, const_value(fc, 1), eltype(a.typ)))
        elseif kind === :array
            o = array_origin(a)
            o === nothing && unsupported("an array argument that does not point into a Memory")
            push!(vals, element_ref!(fc, o, const_value(fc, 1), o.eltype))
        end
    end
    res = call_runtime!(fc, r.f, vals)
    return res.kind === Ghost ? ghost(Nothing, nothing) : res
end
