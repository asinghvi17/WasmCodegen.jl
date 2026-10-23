# Foreign calls: the few calls into Julia's C runtime that Base's code makes for things
# Wasm does natively (allocation, strings as bytes). Others are unsupported; calls into C
# libraries need overlays or host imports.

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
        return emit_memorynew!(fc, constant_value(M), args[2])
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
    elseif name === :memmove || name === :memcpy
        return emit_memmove!(fc, args[1], args[2], args[3], true)
    elseif name === :jl_genericmemory_copyto
        # (dest memory, dest pointer, src memory, src pointer, n elements)
        emit_memmove!(fc, args[2], args[4], args[5], false)
        return ghost(Nothing, nothing)
    elseif name === :memset
        return emit_memset!(fc, args[1], args[2], args[3])
    elseif name === :jl_value_ptr
        # the address of an object: a virtual one (see `push_memory_base!`), pointing into it
        x = args[1]::CGVal
        lx = layout(fc, x.typ)
        (lx.kind === Boxed && ismutabletype(x.typ) && !isempty(lx.fields)) ||
            unsupported("the address of a value of type ", x.typ)
        push_memory_base!(fc, x)
        v = pop_val!(fc, typ)
        return with_origin(v, PtrOrigin(materialize!(fc, x), nothing, nothing, x.typ))
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

"The `String` (or `Symbol`) object of type `T` of the bytes on the stack."
function new_bytes_object!(fc::FnCtx, @nospecialize(T))
    ts = fc.cgm.types
    arr = new_local!(fc, RefType(array_type!(ts, I8), true))
    emit!(fc.b, :local_set, arr)
    emit!(fc.b, :i32_const, typeid!(ts, T))
    emit!(fc.b, :i32_const, 0)
    emit!(fc.b, :local_get, arr)
    emit!(fc.b, :struct_new, bytes_object_type!(ts, T))
    return pop_val!(fc, T)
end

function origin_of(fc::FnCtx, p, what)
    p isa CGVal && p.origin !== nothing && return p.origin
    unsupported(what, " of a pointer whose origin (a Memory) is not known")
end

"""
    emit_memmove!(fc, dst, src, n, bytes) -> CGVal

`memmove` (or `jl_genericmemory_copyto`) between the elements the pointers `dst` and `src`
point to, `n` bytes (or elements): an `array.copy` between the arrays they come from.
"""
function emit_memmove!(fc::FnCtx, dst, src, n, bytes::Bool)
    od, os = origin_of(fc, dst, "memmove"), origin_of(fc, src, "memmove")
    ts = fc.cgm.types
    md, ms = memory_layout(ts, od.eltype), memory_layout(ts, os.eltype)
    md.array == ms.array || unsupported("memmove between memories of ", od.eltype, " and ", os.eltype)
    ml = md
    push_leaf!(fc, od.array)
    push_leaf!(fc, od.index)
    ml.stride != 1 && (emit!(fc.b, :i32_const, ml.stride); emit!(fc.b, :i32_mul))
    push_leaf!(fc, os.array)
    push_leaf!(fc, os.index)
    ml.stride != 1 && (emit!(fc.b, :i32_const, ml.stride); emit!(fc.b, :i32_mul))
    # the number of array elements
    push_val!(fc, n::CGVal)
    layout(fc, n.typ).leaves[1].type === I64 && emit!(fc.b, :i32_wrap_i64)
    if bytes
        sz = Base.aligned_sizeof(od.eltype)
        emit!(fc.b, :i32_const, sz)
        emit!(fc.b, :i32_div_u)
    end
    ml.stride != 1 && (emit!(fc.b, :i32_const, ml.stride); emit!(fc.b, :i32_mul))
    emit!(fc.b, :array_copy, ml.array, ml.array)
    return bytes ? dst : ghost(Nothing, nothing)
end

"""
    emit_memset!(fc, p, val, n) -> CGVal

`memset` of `n` bytes at `p` to the byte `val`: an `array.fill` of a byte array, or of
zeros.
"""
function emit_memset!(fc::FnCtx, p, val, n)
    o = origin_of(fc, p, "memset")
    ml = memory_layout(fc.cgm.types, o.eltype)
    bytewise = ml.storage === I8 && ml.stride == 1
    val = val::CGVal
    if !bytewise && !(isconstant(val) && iszero(constant_value(val)))
        unsupported("memset of a nonzero byte in a memory of ", o.eltype)
    end
    push_leaf!(fc, o.array)
    push_leaf!(fc, o.index)
    ml.stride != 1 && (emit!(fc.b, :i32_const, ml.stride); emit!(fc.b, :i32_mul))
    if bytewise
        push_val!(fc, val)
        layout(fc, val.typ).leaves[1].type === I64 && emit!(fc.b, :i32_wrap_i64)
        emit!(fc.b, :i32_const, 0xff)
        emit!(fc.b, :i32_and)
    else
        st = ml.storage
        push_default!(fc, st isa PackedType ? I32 : st)
    end
    push_val!(fc, n::CGVal)
    layout(fc, n.typ).leaves[1].type === I64 && emit!(fc.b, :i32_wrap_i64)
    if !bytewise
        emit!(fc.b, :i32_const, Base.aligned_sizeof(o.eltype))
        emit!(fc.b, :i32_div_u)
        ml.stride != 1 && (emit!(fc.b, :i32_const, ml.stride); emit!(fc.b, :i32_mul))
    end
    emit!(fc.b, :array_fill, ml.array)
    return p
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

const RUNTIME_CCALLS = Dict{Symbol,RuntimeCcall}()

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
            push!(vals, emit_pointerref!(fc, a, const_value(fc, 1), Any))
        elseif kind === :array
            o = origin_of(fc, a, "an array argument")
            (is_object_origin(o) || o.mem === nothing) &&
                unsupported("an array argument that does not point into a Memory")
            R = memoryref_type(o)
            push!(vals, CGVal(R, Inline, LeafVal[o.mem, o.array, o.index]))
        end
    end
    res = call_runtime!(fc, r.f, vals)
    return res.kind === Ghost ? ghost(Nothing, nothing) : res
end
