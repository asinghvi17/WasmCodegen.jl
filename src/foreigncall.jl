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
        return pop_val!(fc, String)
    elseif name === :jl_string_to_genericmemory
        # strings and Memory{UInt8} are the same arrays
        s = args[1]::CGVal
        return CGVal(Memory{UInt8}, Boxed, s.leaves)
    elseif name === :jl_genericmemory_to_string
        mem, n = args[1]::CGVal, convert_repr(fc, args[2], Int)
        arr = array_type!(fc.cgm.types, I8)
        dst = new_local!(fc, RefType(arr, true))
        push_val!(fc, n)
        emit!(fc.b, :i32_wrap_i64)
        emit!(fc.b, :array_new_default, arr)
        emit!(fc.b, :local_set, dst)
        emit!(fc.b, :local_get, dst); emit!(fc.b, :i32_const, 0)
        push_val!(fc, mem); emit!(fc.b, :i32_const, 0)
        push_val!(fc, n); emit!(fc.b, :i32_wrap_i64)
        emit!(fc.b, :array_copy, arr, arr)
        return CGVal(String, Boxed, LeafVal[dst])
    elseif typ === Union{}
        unreachable!(fc.b)
        return bottom()
    end
    unsupported("the foreign call ", something(name, ex.args[1]))
end
