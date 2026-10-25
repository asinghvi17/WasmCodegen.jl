# Memory: allocation, references to elements, loads and stores.
#
# A `Memory{T}` is an object holding a Wasm array (see `memory_layout`); a `MemoryRef{T}`
# is inline: the Memory, its array (so that accesses do not load it) and the index of its
# element (0-based, in Julia elements).

function ref_eltype(@nospecialize(R))
    is_memoryref_type(R) || unsupported("a memory reference of a type not known at compile time: ", R)
    return memory_eltype(R)
end

# the length (in Julia elements) of the array on the stack, as an i32
function emit_memory_length!(fc::FnCtx, ml::MemoryLayout)
    emit!(fc.b, :array_len)
    if ml.stride != 1
        emit!(fc.b, :i32_const, ml.stride)
        emit!(fc.b, :i32_div_u)
    end
end

"""
    emit_memorynew!(fc, M, n) -> CGVal

A new `Memory` of type `M` with `n` (an `Int`) elements, zeroed (or null).
"""
function emit_memorynew!(fc::FnCtx, @nospecialize(M), n::CGVal)
    is_memory_type(M) || unsupported("memorynew of ", M)
    ml = memory_layout(fc.cgm.types, memory_eltype(M))
    n = convert_repr(fc, n, Int)
    # the length must fit an i32 array length (an error otherwise, as natively for a
    # negative or too large one)
    push_val!(fc, n)
    emit!(fc.b, :i64_const, typemax(Int32) ÷ ml.stride)
    emit!(fc.b, :i64_gt_u)
    if!(fc.b); throw_error!(fc, Runtime.throw_memory_size_error, n); end!(fc.b)
    push_val!(fc, n)
    emit!(fc.b, :i32_wrap_i64)
    if ml.stride != 1
        emit!(fc.b, :i32_const, ml.stride)
        emit!(fc.b, :i32_mul)
    end
    emit!(fc.b, :array_new_default, ml.array)
    return new_memory_object!(fc, M)
end

"The `Memory` object of type `M` of the array on the stack."
function new_memory_object!(fc::FnCtx, @nospecialize(M))
    ts = fc.cgm.types
    arr = new_local!(fc, RefType(memory_array_type!(ts, memory_eltype(M)), true))
    emit!(fc.b, :local_set, arr)
    emit!(fc.b, :i32_const, typeid!(ts, M))
    emit!(fc.b, :i32_const, 0)
    emit!(fc.b, :local_get, arr)
    emit!(fc.b, :struct_new, memory_struct_type!(ts, memory_eltype(M)))
    return pop_val!(fc, M)
end

"Push the array of the `Memory` object `mem`."
function push_memory_array!(fc::FnCtx, mem::CGVal)
    push_val!(fc, mem)
    emit!(fc.b, :struct_get, layout(fc, mem.typ).wtype, DATA_FIELD)
end

"""
    emit_memoryrefnew!(fc, args) -> CGVal

`memoryrefnew(mem)` (a reference to the first element) or `memoryrefnew(ref, i,
boundscheck)` (to the element `i` from `ref`, 1-based).
"""
function emit_memoryrefnew!(fc::FnCtx, args::Vector{Any})
    x = args[1]::CGVal
    orig = x
    if is_memory_type(x.typ) && length(args) > 1
        # memoryrefnew(mem, i, boundscheck) (Julia 1.13): from the first element
        x = emit_memoryrefnew!(fc, Any[x])
    end
    if length(args) == 1
        M = x.typ
        is_memory_type(M) || unsupported("memoryrefnew of ", M)
        R = GenericMemoryRef{M.parameters[1],M.parameters[2],M.parameters[3]}
        push_memory_array!(fc, x)
        arr = new_local!(fc, layout(fc, R).leaves[2].type)
        emit!(fc.b, :local_set, arr)
        return CGVal(R, Inline, LeafVal[only(x.leaves), arr, Inst(:i32_const, 0)])
    end
    R = x.typ
    is_memoryref_type(R) || unsupported("memoryrefnew of ", R)
    i = convert_repr(fc, args[2]::CGVal, Int)
    bc = length(args) >= 3 ? args[3]::CGVal : const_value(fc, true)
    ml = memory_layout(fc.cgm.types, ref_eltype(R))
    # the new index: ref.index + i - 1, as an i64 to check it
    idx = new_local!(fc, I64)
    push_leaf!(fc, x.leaves[3])
    emit!(fc.b, :i64_extend_i32_u)
    push_val!(fc, i)
    emit!(fc.b, :i64_add)
    emit!(fc.b, :i64_const, 1)
    emit!(fc.b, :i64_sub)
    emit!(fc.b, :local_set, idx)
    if !(isconstant(bc) && constant_value(bc) === false)
        # 0 <= idx < length (unsigned compare covers both)
        emit!(fc.b, :local_get, idx)
        push_leaf!(fc, x.leaves[2])
        emit_memory_length!(fc, ml)
        emit!(fc.b, :i64_extend_i32_u)
        emit!(fc.b, :i64_ge_u)
        isconstant(bc) || (push_val!(fc, convert_repr(fc, bc, Bool)); emit!(fc.b, :i32_and))
        if!(fc.b)
        # (as natively: the reference or memory given, and the index given)
        throw_error!(fc, Runtime.throw_bounds_error, () -> convert_repr(fc, orig, Any), i)
        end!(fc.b)
    end
    i32 = new_local!(fc, I32)
    emit!(fc.b, :local_get, idx)
    emit!(fc.b, :i32_wrap_i64)
    emit!(fc.b, :local_set, i32)
    return CGVal(R, Inline, LeafVal[x.leaves[1], x.leaves[2], i32])
end

# push the array and the index of the first array element of the referenced element
function push_element_address!(fc::FnCtx, r::CGVal, ml::MemoryLayout, k::Int=0)
    push_leaf!(fc, r.leaves[2])
    push_leaf!(fc, r.leaves[3])
    if ml.stride != 1
        emit!(fc.b, :i32_const, ml.stride)
        emit!(fc.b, :i32_mul)
    end
    if k != 0
        emit!(fc.b, :i32_const, k)
        emit!(fc.b, :i32_add)
    end
end

# push whether the element `r` refers to is within its memory (an i32): a reference to
# the first element of an empty memory exists, but not its element
function push_in_bounds!(fc::FnCtx, r::CGVal, ml::MemoryLayout)
    push_leaf!(fc, r.leaves[3])
    push_leaf!(fc, r.leaves[2])
    emit!(fc.b, :array_len)
    ml.stride != 1 && (emit!(fc.b, :i32_const, ml.stride); emit!(fc.b, :i32_div_u))
    emit!(fc.b, :i32_lt_u)
end

function array_get_op(st::StorageType)
    st isa PackedType && return :array_get_u
    return :array_get
end

"""
    emit_memoryrefget!(fc, ref, boundscheck, typ) -> CGVal

The element `ref` refers to (the reference was checked when created).
"""
function emit_memoryrefget!(fc::FnCtx, r::CGVal, bc, @nospecialize(typ))
    R = r.typ
    E = ref_eltype(R)
    ml = memory_layout(fc.cgm.types, E)
    el = ml.elem
    check_ref_bounds!(fc, r, ml, bc)
    el.kind === Ghost && return ghost(E, something(ghost_value(E)))
    if ml.boxed
        push_element_address!(fc, r, ml)
        emit!(fc.b, :array_get, ml.array)
        box = CGVal(Any, Boxed, LeafVal[pop_val!(fc, Any).leaves[1]])
        check_defined!(fc, box, E)
        return unbox!(fc, box, E)
    end
    for k in 0:length(el.leaves)-1
        push_element_address!(fc, r, ml, k)
        emit!(fc.b, array_get_op(ml.storage), ml.array)
        ml.widened && narrow_leaf!(fc, el.leaves[k+1].type)
    end
    v = pop_val!(fc, E)
    (el.kind === Boxed || ml.storage isa RefType) && check_defined!(fc, v, E)
    return v
end

# whether natively a value of type `E` never stored (an element, a field) is its zero bits,
# not undefined: of a type stored inline without references (unions: their first type)
zero_defined(@nospecialize(E)) = Base.allocatedinline(E) && (E isa Union || Base.datatype_pointerfree(E))

"The value of the `zero_defined` type `T` of zero bits (a union's: of its first type)."
function zero_bits(@nospecialize(T))
    T isa Union && return zero_bits(first(Base.uniontypes(T)))
    Base.issingletontype(T) && return T.instance
    buf = zeros(UInt8, sizeof(T))
    return GC.@preserve buf unsafe_load(Ptr{T}(pointer(buf)))
end

# with `v` (in locals) a value of type `E` stored as references, where a null first one is a
# value never stored: that is its zero bits where natively it is (`zero_defined`), else an
# error (UndefRefError)
function check_defined!(fc::FnCtx, v::CGVal, @nospecialize(E))
    k = findfirst(l -> l.type isa RefType, layout(fc, v.typ).leaves)
    push_leaf!(fc, v.leaves[k])
    emit!(fc.b, :ref_is_null)
    if!(fc.b)
    if zero_defined(E)
        assign!(fc, v, const_value(fc, zero_bits(E)))
    else
        throw_error!(fc, Runtime.throw_undefref_error)
    end
    end!(fc.b)
end

"""
    emit_memoryrefset!(fc, ref, v, boundscheck) -> CGVal

Store `v` in the element `ref` refers to.
"""
function emit_memoryrefset!(fc::FnCtx, r::CGVal, v::CGVal, bc)
    R = r.typ
    E = ref_eltype(R)
    ml = memory_layout(fc.cgm.types, E)
    v = convert_repr(fc, v, E)
    v.kind === Bottom && return v
    check_ref_bounds!(fc, r, ml, bc)
    el = ml.elem
    el.kind === Ghost && return v
    if ml.boxed
        b = box!(fc, v, Any)
        push_element_address!(fc, r, ml)
        push_val!(fc, b)
        is_union_tuple(E) || emit!(fc.b, :ref_cast_null, box_type!(fc.cgm.types, E))
        emit!(fc.b, :array_set, ml.array)
        return v
    end
    for (k, leaf) in enumerate(v.leaves)
        push_element_address!(fc, r, ml, k - 1)
        push_leaf!(fc, leaf)
        ml.widened && widen_leaf!(fc, el.leaves[k].type)
        emit!(fc.b, :array_set, ml.array)
    end
    return v
end

# a leaf of type `t` on the stack, to its widened (i64) storage and back
function widen_leaf!(fc::FnCtx, t::ValType)
    if t === I32
        emit!(fc.b, :i64_extend_i32_u)
    elseif t === F32
        emit!(fc.b, :i32_reinterpret_f32)
        emit!(fc.b, :i64_extend_i32_u)
    elseif t === F64
        emit!(fc.b, :i64_reinterpret_f64)
    end
end

function narrow_leaf!(fc::FnCtx, t::ValType)
    if t === I32
        emit!(fc.b, :i32_wrap_i64)
    elseif t === F32
        emit!(fc.b, :i32_wrap_i64)
        emit!(fc.b, :f32_reinterpret_i32)
    elseif t === F64
        emit!(fc.b, :f64_reinterpret_i64)
    end
end

# whether the element `r` refers to is assigned: within the memory, and, for references,
# not null
function emit_memoryref_isassigned!(fc::FnCtx, r::CGVal, bc)
    E = ref_eltype(r.typ)
    ml = memory_layout(fc.cgm.types, E)
    push_in_bounds!(fc, r, ml)
    # (an element never stored is undefined if natively it is)
    if (ml.boxed || ml.elem.kind === Boxed || (ml.storage isa RefType)) && !zero_defined(E)
        if!(fc.b, I32)
        push_element_address!(fc, r, ml)
        emit!(fc.b, :array_get, ml.array)
        emit!(fc.b, :ref_is_null)
        emit!(fc.b, :i32_eqz)
        else!(fc.b)
        emit!(fc.b, :i32_const, 0)
        end!(fc.b)
    end
    return pop_val!(fc, Bool)
end

# a BoundsError for the element at the 0-based index `idx()` (an Int) of the memory the
# reference `r` refers into
function throw_bounds!(fc::FnCtx, r::CGVal, idx)
    R = r.typ
    M = GenericMemory{R.parameters[1],R.parameters[2],R.parameters[3]}
    mem = () -> convert_repr(fc, CGVal(M, Boxed, LeafVal[r.leaves[1]]), Any)
    i = () -> (push_val!(fc, idx()); emit!(fc.b, :i64_const, 1); emit!(fc.b, :i64_add); pop_val!(fc, Int))
    throw_error!(fc, Runtime.throw_bounds_error, mem, i)
end

# with `boundscheck`, that the reference `r` is to an element of its memory (a reference to
# the first element of an empty memory is not): a BoundsError otherwise
function check_ref_bounds!(fc::FnCtx, r::CGVal, ml::MemoryLayout, bc)
    bc isa CGVal && isconstant(bc) && constant_value(bc) === false && return
    push_in_bounds!(fc, r, ml)
    emit!(fc.b, :i32_eqz)
    if bc isa CGVal && !isconstant(bc)
        push_val!(fc, convert_repr(fc, bc, Bool)); emit!(fc.b, :i32_and)
    end
    if!(fc.b)
    throw_bounds!(fc, r, () -> (push_leaf!(fc, r.leaves[3]); emit!(fc.b, :i64_extend_i32_u); pop_val!(fc, Int)))
    end!(fc.b)
end
