# The image: the Julia objects the code refers to, serialized into the module.
#
# Every object is an immutable global of the module, whose initializer (a constant
# expression) builds it: `struct.new` with its fields, `array.new_fixed` with its
# elements. Fields that refer to other objects are `global.get`s of their globals, which
# are emitted first (depth-first postorder). A reference to an object whose global does
# not exist yet (a cycle) is null in the initializer, and set by the module's start
# function. Large arrays of numbers are filled by the start function from data segments.
#
# Objects are keyed by identity (`IdDict`), so that an object referred to from several
# places is one object in the module, as it is in Julia's heap.

"""
    Image

The serialized objects of a module: the global of each object, the objects being
serialized (to detect cycles), and the start function's instructions that complete them.
"""
mutable struct Image
    cgm::Any
    globals::IdDict{Any,Global}
    boxes::IdDict{Any,Global}
    singletons::IdDict{Any,Global}
    inprogress::IdSet{Any}
    "Instructions of the start function: stores of the references of cycles, array fills."
    init::Vector{Inst}
    "The objects whose global is being built, with the stores to make once it exists."
    pending::IdDict{Any,Vector{Any}}
    "Global variables: (module, name) => the globals of the leaves of its value."
    vars::Dict{Tuple{Module,Symbol},Tuple{Any,Vector{Global}}}
    counter::Int
end

Image(cgm) = Image(cgm, IdDict{Any,Global}(), IdDict{Any,Global}(), IdDict{Any,Global}(),
                   IdSet{Any}(), Inst[], IdDict{Any,Vector{Any}}(),
                   Dict{Tuple{Module,Symbol},Tuple{Any,Vector{Global}}}(), 0)

types(img::Image) = img.cgm.types

"The maximum number of elements of an array built by `array.new_fixed` in an initializer."
const MAX_FIXED_ELEMENTS = 10_000
"The maximum number of bytes of a numeric array built by `array.new_fixed`."
const MAX_FIXED_BYTES = 256

function global_name(img::Image, @nospecialize(x))
    img.counter += 1
    T = typeof(x)
    base = T isa DataType ? string(T.name.name) : "obj"
    return string("jl_", replace(base, r"[^A-Za-z0-9_]" => "_"), "#", img.counter)
end

## constants in code

"""
    const_value(fc, x) -> CGVal

The compile-time constant `x`: a ghost, constant leaves (numbers, and `global.get`s of
the objects an inline value refers to), or a reference to its object in the image.
"""
function const_value(fc::FnCtx, @nospecialize(x))
    T = Core.Typeof(x)
    l = layout(fc, T)
    l.kind === Ghost && return ghost(T, x)
    if l.kind === Inline
        return CGVal(T, Inline, const_leaves(fc.cgm.image, x, T), Some{Any}(x))
    end
    g = object_global!(fc.cgm.image, x)
    return CGVal(T, Boxed, LeafVal[Inst(:global_get, g)], Some{Any}(x))
end

function primitive_const(@nospecialize(x), leaves::Vector{Leaf})
    T = typeof(x)
    if T === Float64
        return Inst[Inst(:f64_const, x)]
    elseif T === Float32
        return Inst[Inst(:f32_const, x)]
    end
    sz = sizeof(T)
    if sz == 16
        u = Core.bitcast(UInt128, x)
        return Inst[Inst(:i64_const, reinterpret(Int64, UInt64(u & typemax(UInt64)))),
                    Inst(:i64_const, reinterpret(Int64, UInt64(u >> 64)))]
    elseif sz == 8
        return Inst[Inst(:i64_const, reinterpret(Int64, Core.bitcast(UInt64, x)))]
    elseif sz == 4
        return Inst[Inst(:i32_const, reinterpret(Int32, Core.bitcast(UInt32, x)))]
    elseif sz == 2
        return Inst[Inst(:i32_const, Int32(Core.bitcast(UInt16, x)))]
    elseif sz == 1
        return Inst[Inst(:i32_const, Int32(Core.bitcast(UInt8, x)))]
    end
    unsupported("a constant of the primitive type ", T)
end

"""
    const_leaves(img, x, FT) -> Vector{Inst}

The leaves of the value `x` stored where the declared type is `FT` (a field, an
element): constant instructions, `global.get`s of objects.
"""
function const_leaves(img::Image, @nospecialize(x), @nospecialize(FT))
    ts = types(img)
    lf = layout(ts, FT)
    lf.kind === Ghost && return Inst[]
    if lf.kind === Inline
        T = typeof(x)
        isprimitivetype(T) && return primitive_const(x, lf.leaves)
        is_memoryref_type(T) && unsupported("a constant MemoryRef")
        leaves = Inst[]
        for i in 1:fieldcount(T)
            FTi = fieldtype(T, i)
            if isdefined(x, i)
                append!(leaves, const_leaves(img, getfield(x, i), FTi))
            else
                append!(leaves, Inst[default_inst(l.type) for l in field_leaves(ts, FTi)])
            end
        end
        return leaves
    end
    # a reference
    if lf.wtype == ts.jlvalue
        return Inst[Inst(:global_get, boxed_object_global!(img, x))]
    end
    return Inst[Inst(:global_get, object_global!(img, x))]
end

## objects

"""
    boxed_object_global!(img, x) -> Global

A global holding `x` as a `\$JlValue`: its object if it is one, else a box (for inline
values, ghosts, `Memory` and `String`).
"""
function boxed_object_global!(img::Image, @nospecialize(x))
    ts = types(img)
    T = typeof(x)
    l = layout(ts, T)
    if l.kind === Boxed && is_jlvalue_type(ts, T)
        return object_global!(img, x)
    elseif l.kind === Ghost
        return singleton_global!(img, T)
    end
    # isbits values are boxed once per value; others (Memory, String) per object
    get!(img.boxes, x) do
        box = box_type!(ts, T)
        init = Inst[Inst(:i32_const, typeid!(ts, T)), Inst(:i32_const, 0)]
        if l.kind === Inline
            append!(init, const_leaves(img, x, T))
        else
            push!(init, Inst(:global_get, object_global!(img, x)))
        end
        push!(init, Inst(:struct_new, box))
        add_global!(img.cgm.mod, global_name(img, x), RefType(box, false), false, init)
    end
end

"""
    singleton_global!(img, T) -> Global

The object of the singleton (ghost) type `T`, where it is stored as a `\$JlValue`.
"""
function singleton_global!(img::Image, @nospecialize(T))
    get!(img.singletons, T) do
        ts = types(img)
        box = box_type!(ts, T)
        init = Inst[Inst(:i32_const, typeid!(ts, T)), Inst(:i32_const, 0),
                    Inst(:struct_new, box)]
        add_global!(img.cgm.mod, string("jl_singleton_", img.counter += 1), RefType(box, false),
                    false, init)
    end
end

"""
    object_global!(img, x) -> Global

The global of the object `x` (of a boxed type), serializing it (and the objects it refers
to) on first use.
"""
function object_global!(img::Image, @nospecialize(x))
    g = get(img.globals, x, nothing)
    g === nothing || return g
    ts = types(img)
    T = typeof(x)
    l = layout(ts, T)
    l.kind === Boxed || unsupported("an object of the inline type ", T)
    if T === String
        return array_global!(img, x, codeunits(x), UInt8)
    elseif is_memory_type(T)
        return memory_global!(img, x)
    elseif T === Symbol
        g = object_global_symbol!(img, x)
    elseif any(R -> T === R, RUNTIME_TYPES) || T isa DataType && T <: Type
        unsupported("serializing the runtime object ", x, " of type ", T)
    elseif T <: Ptr || T === Ptr
        unsupported("serializing a pointer")
    else
        g = struct_global!(img, x, l)
    end
    return g
end

function object_global_symbol!(img::Image, s::Symbol)
    ts = types(img)
    bytes = Vector{UInt8}(codeunits(String(s)))
    arr = array_type!(ts, I8)
    init = Inst[Inst(:i32_const, typeid!(ts, Symbol)), Inst(:i32_const, 0)]
    for b in bytes
        push!(init, Inst(:i32_const, Int32(b)))
    end
    push!(init, Inst(:array_new_fixed, arr, length(bytes)))
    push!(init, Inst(:struct_new, symbol_type!(ts)))
    g = add_global!(img.cgm.mod, "jl_sym_" * replace(String(s), r"[^A-Za-z0-9_]" => "_"),
                    RefType(symbol_type!(ts), false), false, init)
    img.globals[s] = g
    return g
end

# the leaves of the field value `v` (declared type FT) of an object being serialized, with
# null for references to objects being serialized (cycles), recorded in `back`
function field_init!(img::Image, @nospecialize(v), @nospecialize(FT), back::Vector{Any}, slot)
    ts = types(img)
    lf = layout(ts, FT)
    if lf.kind === Boxed
        target = lf.wtype == ts.jlvalue && !(layout(ts, typeof(v)).kind === Boxed &&
                                             is_jlvalue_type(ts, typeof(v))) ? nothing : v
        if target !== nothing && target in img.inprogress
            push!(back, (slot, v, FT))
            return Inst[Inst(:ref_null, lf.leaves[1].type.heap)]
        end
    end
    return const_leaves(img, v, FT)
end

function struct_global!(img::Image, @nospecialize(x), l::Layout)
    ts = types(img)
    T = typeof(x)
    push!(img.inprogress, x)
    back = Any[]
    init = Inst[Inst(:i32_const, typeid!(ts, T)), Inst(:i32_const, 0)]
    try
        for i in 1:fieldcount(T)
            FT = fieldtype(T, i)
            if isdefined(x, i)
                append!(init, field_init!(img, getfield(x, i), FT, back, first(l.fields[i]) - 1))
            else
                append!(init, Inst[default_inst(leaf.type) for leaf in field_leaves(ts, FT)])
            end
        end
    finally
        delete!(img.inprogress, x)
    end
    push!(init, Inst(:struct_new, l.wtype))
    g = add_global!(img.cgm.mod, global_name(img, x), RefType(l.wtype, false), false, init)
    img.globals[x] = g
    if !isempty(back)
        ismutabletype(T) || unsupported("a cycle of objects through the immutable ", T)
        for (wfield, v, FT) in back
            # set by the start function, once every global exists
            push!(img.init, Inst(:global_get, g))
            append!(img.init, const_leaves(img, v, FT))
            push!(img.init, Inst(:struct_set, l.wtype, wfield))
        end
    end
    return g
end

function memory_global!(img::Image, mem)
    T = typeof(mem)
    E = memory_eltype(T)
    ml = memory_layout(types(img), E)
    el = ml.elem
    if el.kind === Ghost || el.kind === Bottom
        return add_array_global!(img, mem, ml.array, length(mem), Inst[], true)
    end
    if el.kind === Inline && !ml.boxed && !(ml.storage isa RefType)
        # numbers: the bytes of the leaves
        return numeric_memory_global!(img, mem, ml)
    end
    # references (to objects, or boxes of inline elements)
    n = length(mem) * ml.stride
    push!(img.inprogress, mem)
    back = Any[]
    elems = Inst[]
    try
        for i in 1:length(mem)
            if !isassigned(mem, i)
                append!(elems, Inst[Inst(:ref_null, (ml.storage::RefType).heap) for _ in 1:ml.stride])
                continue
            end
            v = mem[i]
            if ml.boxed
                push!(elems, Inst(:global_get, boxed_object_global!(img, v)))
            else
                append!(elems, field_init!(img, v, E, back, i - 1))
            end
        end
    finally
        delete!(img.inprogress, mem)
    end
    fixed = n <= MAX_FIXED_ELEMENTS
    g = add_array_global!(img, mem, ml.array, n, fixed ? elems : Inst[], !fixed)
    if !fixed
        # set by the start function, element by element
        for (i, e) in enumerate(elems)
            push!(img.init, Inst(:global_get, g), Inst(:i32_const, i - 1), e,
                  Inst(:array_set, ml.array))
        end
    end
    for (i, v, FT) in back
        push!(img.init, Inst(:global_get, g), Inst(:i32_const, i * ml.stride))
        append!(img.init, const_leaves(img, v, FT))
        push!(img.init, Inst(:array_set, ml.array))
    end
    return g
end

# a global of the array type `arr` with `n` elements: `elems` (array.new_fixed), or
# default ones (array.new_default)
function add_array_global!(img::Image, @nospecialize(x), arr::TypeRef, n::Int,
                           elems::Vector{Inst}, default::Bool)
    init = if default
        Inst[Inst(:i32_const, n), Inst(:array_new_default, arr)]
    else
        Inst[elems..., Inst(:array_new_fixed, arr, n)]
    end
    g = add_global!(img.cgm.mod, global_name(img, x), RefType(arr, false), false, init)
    img.globals[x] = g
    return g
end

# the bytes of the array elements of a memory of numbers, in the order of the leaves
function leaf_bytes(mem, ml::MemoryLayout)
    io = IOBuffer()
    for i in 1:length(mem)
        insts = const_leaves_bits(mem[i])
        for x in insts
            write_storage_bytes(io, x, ml.storage)
        end
    end
    return take!(io)
end

# the primitive leaves of an isbits value, as Julia values
function const_leaves_bits(@nospecialize(x))
    T = typeof(x)
    isprimitivetype(T) && return Any[x]
    out = Any[]
    for i in 1:fieldcount(T)
        append!(out, const_leaves_bits(getfield(x, i)))
    end
    return out
end

function write_storage_bytes(io::IO, @nospecialize(x), st::StorageType)
    T = typeof(x)
    if st === I8
        write(io, Core.bitcast(UInt8, x))
    elseif st === I16
        write(io, Core.bitcast(UInt16, x))
    elseif st === I32 || st === F32
        write(io, htol(sizeof(T) == 4 ? Core.bitcast(UInt32, x) : UInt32(Core.bitcast(UInt8, x))))
    elseif st === I64 || st === F64
        write(io, htol(Core.bitcast(UInt64, x)))
    else
        error("storage $st")
    end
end

function numeric_memory_global!(img::Image, mem, ml::MemoryLayout)
    n = length(mem) * ml.stride
    bytes = leaf_bytes(mem, ml)
    if length(bytes) <= MAX_FIXED_BYTES
        elems = Inst[]
        for i in 1:length(mem), x in const_leaves_bits(mem[i])
            st = ml.storage
            if st === F64
                push!(elems, Inst(:f64_const, Float64(x)))
            elseif st === F32
                push!(elems, Inst(:f32_const, Float32(x)))
            elseif st === I64
                push!(elems, Inst(:i64_const, reinterpret(Int64, Core.bitcast(UInt64, x))))
            else
                push!(elems, primitive_const(x, Leaf[])[1])
            end
        end
        return add_array_global!(img, mem, ml.array, n, elems, false)
    end
    return data_array_global!(img, mem, ml.array, n, bytes)
end

# an array global filled by the start function from a data segment
function data_array_global!(img::Image, @nospecialize(x), arr::TypeRef, n::Int,
                            bytes::Vector{UInt8})
    g = add_array_global!(img, x, arr, n, Inst[], true)
    seg = add_data!(img.cgm.mod, bytes)
    push!(img.init, Inst(:global_get, g), Inst(:i32_const, 0), Inst(:i32_const, 0),
          Inst(:i32_const, n), Inst(:array_init_data, arr, seg))
    return g
end

function array_global!(img::Image, @nospecialize(x), bytes, ::Type{UInt8})
    arr = array_type!(types(img), I8)
    n = length(bytes)
    if n <= MAX_FIXED_BYTES
        elems = Inst[Inst(:i32_const, Int32(b)) for b in bytes]
        return add_array_global!(img, x, arr, n, elems, false)
    end
    return data_array_global!(img, x, arr, n, Vector{UInt8}(bytes))
end

## global variables

"""
    nonconst_global(fc, ref) -> CGVal

A read of the global variable `ref`: mutable globals of the module (one per leaf of its
declared type), initialized with its value at compile time.
"""
function nonconst_global(fc::FnCtx, ref::GlobalRef)
    T, gs = global_var!(fc.cgm.image, ref)
    l = layout(fc, T)
    l.kind === Ghost && return ghost(T, something(ghost_value(T)))
    for g in gs
        emit!(fc.b, :global_get, g)
    end
    return pop_val!(fc, T)
end

function global_var!(img::Image, ref::GlobalRef)
    key = (ref.mod, ref.name)
    haskey(img.vars, key) && return img.vars[key]
    T = Base.invoke_in_world(img.cgm.world.world, Core.get_binding_type, ref.mod, ref.name)
    ts = types(img)
    l = layout(ts, T)
    defined = Base.invoke_in_world(img.cgm.world.world, isdefinedglobal, ref.mod, ref.name)
    inits = if defined
        v = Base.invoke_in_world(img.cgm.world.world, getglobal, ref.mod, ref.name)
        const_leaves(img, v, T)
    else
        Inst[default_inst(leaf.type) for leaf in l.leaves]
    end
    gs = Global[]
    for (i, leaf) in enumerate(l.leaves)
        name = string("jl_global_", ref.mod, "_", ref.name, length(l.leaves) > 1 ? "_$i" : "")
        push!(gs, add_global!(img.cgm.mod, name, leaf.type, true, Inst[inits[i]]))
    end
    img.vars[key] = (T, gs)
    return (T, gs)
end

"Write the global variable `ref` (a `setglobal!`)."
function set_global_var!(fc::FnCtx, ref::GlobalRef, v::CGVal)
    T, gs = global_var!(fc.cgm.image, ref)
    v = convert_repr(fc, v, T)
    v.kind === Bottom && return v
    push_val!(fc, v)
    for g in Iterators.reverse(gs)
        emit!(fc.b, :global_set, g)
    end
    return v
end

## finishing

"""
    finish_image!(cgm)

Add the start function, which completes the objects of the image (references in cycles,
large arrays).
"""
function finish_image!(cgm::CGModule)
    img = cgm.image
    isempty(img.init) && return
    f = add_func!(cgm.mod, "jl_init_image", ValType[], ValType[])
    b = Builder(cgm.mod, f)
    for inst in img.init
        emit!(b, inst.op, inst.imm...)
    end
    finish!(b)
    cgm.mod.start = f
end
