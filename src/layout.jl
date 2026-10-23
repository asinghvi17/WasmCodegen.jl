# How Julia values are represented: the kind of representation of a type, its leaves (the
# Wasm values of an inline value), and the Wasm types of objects.

"""
    Kind

The representation of the values of a type:

- `Ghost`: no run-time representation (singletons, zero-size types, unique `Type{T}`);
- `Inline`: a flat list of Wasm values, the *leaves* (primitives, immutable structs,
  tuples and closures, whose leaves are their fields' leaves);
- `Boxed`: a reference to an object (mutable types, abstract types, unions, `Memory`,
  `String`, large immutable values);
- `Bottom`: no value (`Union{}`).
"""
@enum Kind Ghost Inline Boxed Bottom

"""
    Leaf(type, storage)

A Wasm value of an inline value: its type on the operand stack, and how it is stored in
a field or an array (packed `i8`/`i16` for small integers).
"""
struct Leaf
    type::ValType
    storage::StorageType
end
Leaf(t::ValType) = Leaf(t, t)

"""
    Layout

The representation of a Julia type `T`: its kind, its leaves (one reference for a boxed
type), and for structs the leaves (inline) or the Wasm fields (mutable structs) of each
field. `wtype` is the Wasm type of the objects of a boxed type (a struct or an array).
"""
mutable struct Layout
    T::Any
    kind::Kind
    leaves::Vector{Leaf}
    fields::Vector{UnitRange{Int}}
    wtype::Union{Nothing,TypeRef}
end

"The maximum number of leaves of an inline type; larger immutable types are boxed."
const MAX_INLINE_LEAVES = 64

"The number of Wasm fields of the header of every object: the type id and the hash."
const HEADER_FIELDS = 2

"""
    Types

The Wasm types of a module for Julia types: layouts, the object header type `\$JlValue`,
array types by element storage, boxes, type ids.
"""
mutable struct Types
    mod::WModule
    layouts::IdDict{Any,Layout}
    jlvalue::TypeRef
    arrays::Dict{StorageType,TypeRef}
    boxes::IdDict{Any,TypeRef}
    typeids::IdDict{Any,Int32}
    "The types by type id (1-based)."
    typelist::Vector{Any}
    "The layouts being computed (to detect types containing themselves)."
    inprogress::IdSet{Any}
end

function Types(m::WModule)
    jlvalue = add_type!(m, StructType([FieldType(I32, false), FieldType(I32, true)]);
                        final=false)
    return Types(m, IdDict{Any,Layout}(), jlvalue, Dict{StorageType,TypeRef}(),
                 IdDict{Any,TypeRef}(), IdDict{Any,Int32}(), Any[], IdSet{Any}())
end

"The reference type of `\$JlValue` objects (any boxed Julia value)."
jlvalue_ref(ts::Types) = RefType(ts.jlvalue, true)

"""
    typeid!(ts, T) -> Int32

The type id of the concrete type `T` (assigned on first use, from 1).
"""
function typeid!(ts::Types, @nospecialize(T))
    get!(ts.typeids, T) do
        push!(ts.typelist, T)
        Int32(length(ts.typelist))
    end
end

## ghosts and kinds

"""
    unique_type_parameter(T) -> Union{Some,Nothing}

The `X` of a `Type{X}` that only `X` is an instance of, or `nothing` (as JuliaCodegen).
"""
function unique_type_parameter(@nospecialize T)
    (T isa DataType && T.name === Type.body.name) || return nothing
    X = T.parameters[1]
    has_unique_rep(X) || return nothing
    return Some(X)
end

function has_unique_rep(@nospecialize X)
    X === typeof(Union{}) && return false
    X === Union{} && return true
    X isa TypeVar && return false
    X isa Type || return true
    isconcretetype(X) && return true
    if X isa DataType && X.name !== Tuple.name
        return all(has_unique_rep, X.parameters)
    end
    return false
end

"""
    ghost_value(T) -> Union{Some,Nothing}

The only value of type `T` if it is a singleton type, else `nothing`.
"""
function ghost_value(@nospecialize T)
    X = unique_type_parameter(T)
    X === nothing || return X
    T isa DataType || return nothing
    !ismutabletype(T) && isdefined(T, :instance) && return Some(T.instance)
    return nothing
end

function is_inline_tuple(@nospecialize T)
    (T isa DataType && T.name === Tuple.name && !isconcretetype(T) && !Base.isvatuple(T)) ||
        return false
    return all(P -> (P isa DataType && isconcretetype(P)) || unique_type_parameter(P) !== nothing ||
                    is_inline_tuple(P), T.parameters)
end

is_memory_type(@nospecialize T) = T isa DataType && T.name === GenericMemory.body.body.body.name
is_memoryref_type(@nospecialize T) =
    T isa DataType && T.name === GenericMemoryRef.body.body.body.name
memory_eltype(@nospecialize T) = T.parameters[2]

# the runtime's own objects, which have no Julia-level layout to follow
const RUNTIME_TYPES = Any[DataType, UnionAll, Union, Core.TypeofBottom, TypeVar,
                          Core.SimpleVector, Module, Method, Core.MethodInstance,
                          Core.CodeInstance, Task, Core.TypeName]

function primitive_leaves(@nospecialize T)
    T === Float64 && return [Leaf(F64)]
    T === Float32 && return [Leaf(F32)]
    sz = sizeof(T)
    sz == 1 && return [Leaf(I32, I8)]
    sz == 2 && return [Leaf(I32, I16)]
    sz == 4 && return [Leaf(I32)]
    sz == 8 && return [Leaf(I64)]
    sz == 16 && return [Leaf(I64), Leaf(I64)]
    unsupported("the primitive type ", T, " of ", sz, " bytes")
end

"""
    layout(ts, T) -> Layout

The representation of values of type `T`.
"""
function layout(ts::Types, @nospecialize(T))
    l = get(ts.layouts, T, nothing)
    l === nothing || return l
    T in ts.inprogress && unsupported("the type ", T, ", which contains itself inline")
    push!(ts.inprogress, T)
    try
        l = compute_layout(ts, T)
    finally
        delete!(ts.inprogress, T)
    end
    ts.layouts[T] = l
    return l
end

function boxed_layout(ts::Types, @nospecialize(T), wtype::TypeRef)
    return Layout(T, Boxed, [Leaf(RefType(wtype, true))], UnitRange{Int}[], wtype)
end

function compute_layout(ts::Types, @nospecialize(T))
    T === Union{} && return Layout(T, Bottom, Leaf[], UnitRange{Int}[], nothing)
    ghost_value(T) === nothing ||
        return Layout(T, Ghost, Leaf[], UnitRange{Int}[], nothing)
    # a tuple with singleton `Type{X}` elements (varargs packed by the IR) is not a
    # concrete type, but its values are inline all the same
    is_inline_tuple(T) && return immutable_layout(ts, T)
    if !(T isa DataType) || !isconcretetype(T) || any(R -> T === R, RUNTIME_TYPES)
        # abstract types, unions, type objects: any object
        return Layout(T, Boxed, [Leaf(jlvalue_ref(ts))], UnitRange{Int}[], ts.jlvalue)
    end
    if isprimitivetype(T)
        return Layout(T, Inline, primitive_leaves(T), UnitRange{Int}[], nothing)
    elseif is_memory_type(T)
        return boxed_layout(ts, T, memory_array_type!(ts, memory_eltype(T)))
    elseif T === String
        return boxed_layout(ts, T, array_type!(ts, I8))
    elseif T === Symbol
        return boxed_layout(ts, T, symbol_type!(ts))
    elseif is_memoryref_type(T)
        # the array and the index of the element (0-based)
        arr = memory_array_type!(ts, memory_eltype(T))
        return Layout(T, Inline, [Leaf(RefType(arr, true)), Leaf(I32)], UnitRange{Int}[], nothing)
    elseif ismutabletype(T)
        return mutable_struct_layout(ts, T)
    else
        return immutable_layout(ts, T)
    end
end

"""
    field_leaves(ts, FT) -> Vector{Leaf}

The leaves a field of declared type `FT` occupies in its parent: those of an inline type,
one reference for a boxed one (unions included: Julia stores some inline, they are boxed
here), none for a ghost.
"""
function field_leaves(ts::Types, @nospecialize(FT))
    l = layout(ts, FT)
    l.kind === Ghost && return Leaf[]
    l.kind === Bottom && return Leaf[]
    return l.leaves
end

function struct_field_ranges(ts::Types, @nospecialize(T), offset::Int)
    leaves = Leaf[]
    ranges = UnitRange{Int}[]
    for i in 1:fieldcount(T)
        fl = field_leaves(ts, fieldtype(T, i))
        start = length(leaves) + 1
        append!(leaves, fl)
        push!(ranges, (start:length(leaves)) .+ offset)
    end
    return leaves, ranges
end

function immutable_layout(ts::Types, @nospecialize(T))
    leaves, ranges = struct_field_ranges(ts, T, 0)
    if length(leaves) > MAX_INLINE_LEAVES
        # a large immutable value: an immutable object
        l = boxed_layout(ts, T, box_type!(ts, T, leaves))
        l.fields = [r .+ HEADER_FIELDS for r in ranges]
        return l
    end
    return Layout(T, Inline, leaves, ranges, nothing)
end

function mutable_struct_layout(ts::Types, @nospecialize(T))
    # declare the type first: fields may refer to it
    m = ts.mod
    idx = length(m.types)
    wtype = TypeRef(idx)
    push!(m.types, SubType(StructType(FieldType[]); final=true, super=ts.jlvalue))
    l = boxed_layout(ts, T, wtype)
    ts.layouts[T] = l
    leaves, ranges = struct_field_ranges(ts, T, HEADER_FIELDS)
    fields = FieldType[FieldType(I32, false), FieldType(I32, true)]
    for leaf in leaves
        push!(fields, FieldType(nullable_storage(leaf.storage), true))
    end
    m.types[idx+1] = SubType(StructType(fields); final=true, super=ts.jlvalue)
    l.fields = ranges
    return l
end

nullable_storage(t::RefType) = RefType(t.heap, true)
nullable_storage(t) = t

## arrays

"""
    array_type!(ts, storage) -> TypeRef

The Wasm array type with mutable elements of `storage` (shared by all Julia types whose
elements are stored that way).
"""
function array_type!(ts::Types, storage::StorageType)
    get!(ts.arrays, storage) do
        add_type!(ts.mod, ArrayType(FieldType(storage, true)))
    end
end

"""
    MemoryLayout

How the elements of a `Memory{T}` are stored: in an array of `storage`, `stride` array
elements per Julia element (the leaves of an inline element whose leaves are stored
alike), or `boxed` (a reference per element to a box of an inline element).
"""
struct MemoryLayout
    elem::Layout
    array::TypeRef
    storage::StorageType
    stride::Int
    boxed::Bool
end

function memory_layout(ts::Types, @nospecialize(E))
    el = layout(ts, E)
    if el.kind === Ghost || el.kind === Bottom
        return MemoryLayout(el, array_type!(ts, I8), I8, 1, false)
    end
    leaves = el.leaves
    s = leaves[1].storage
    if el.kind === Boxed
        return MemoryLayout(el, array_type!(ts, nullable_storage(s)), nullable_storage(s), 1, false)
    end
    if all(l -> l.storage == s, leaves)
        st = nullable_storage(s)
        return MemoryLayout(el, array_type!(ts, st), st, length(leaves), false)
    end
    box = box_type!(ts, E)
    st = RefType(box, true)
    return MemoryLayout(el, array_type!(ts, st), st, 1, true)
end

memory_array_type!(ts::Types, @nospecialize(E)) = memory_layout(ts, E).array

## objects

"""
    box_type!(ts, T) -> TypeRef

The Wasm struct type of boxes of values of the inline (or ghost) type `T`: the header
and its leaves, immutable. For `Memory` and `String`, the box holds the array.
"""
function box_type!(ts::Types, @nospecialize(T), leaves::Vector{Leaf}=Leaf[])
    get!(ts.boxes, T) do
        if isempty(leaves)
            l = layout(ts, T)
            leaves = l.kind === Ghost ? Leaf[] : l.leaves
        end
        fields = FieldType[FieldType(I32, false), FieldType(I32, true)]
        for leaf in leaves
            push!(fields, FieldType(nullable_storage(leaf.storage), false))
        end
        add_type!(ts.mod, StructType(fields); final=true, super=ts.jlvalue)
    end
end

"The Wasm struct type of `Symbol`s: the header and the name (bytes)."
function symbol_type!(ts::Types)
    get!(ts.boxes, Symbol) do
        bytes = array_type!(ts, I8)
        add_type!(ts.mod, StructType([FieldType(I32, false), FieldType(I32, true),
                                       FieldType(RefType(bytes, true), false)]);
                  final=true, super=ts.jlvalue)
    end
end

"Whether the objects of the boxed type `T` are `\$JlValue`s (as opposed to Wasm arrays)."
is_jlvalue_type(ts::Types, @nospecialize(T)) = !(is_memory_type(T) || T === String)

"""
    valtypes(ts, T) -> Vector{ValType}

The Wasm types of the leaves of values of type `T` (parameters, results, locals).
"""
valtypes(ts::Types, @nospecialize(T)) = ValType[l.type for l in layout(ts, T).leaves]
