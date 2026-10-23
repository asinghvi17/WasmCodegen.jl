# Foreign calls: the few calls into Julia's C runtime that Base's code makes for things
# Wasm does natively (allocation, strings as bytes). Others are unsupported; calls into C
# libraries need overlays or host imports.

function foreigncall_name(@nospecialize(x))
    x isa QuoteNode && (x = x.value)
    x isa Symbol && return x
    x isa Tuple && return x[1] isa Symbol ? x[1] : nothing
    if x isa Expr && x.head === :call && length(x.args) >= 2
        return foreigncall_name(x.args[2])
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
