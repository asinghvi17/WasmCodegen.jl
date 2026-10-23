# Values in generated code.

"A leaf of a value: a local of the function, or one instruction that pushes a constant."
const LeafVal = Union{Int,Inst}

"""
    PtrOrigin(array, index, eltype)

Where a pointer points: the element `index` (an i32 leaf, 0-based) of the array (a leaf)
of a Memory of elements of type `eltype`. Pointers cannot be dereferenced on Wasm; the
operations Base makes with pointers into memory (`memmove`, `memset`) are compiled from
the origins of their pointers.
"""
struct PtrOrigin
    array::Any
    index::Any
    eltype::Any
end

"""
    CGVal

A value in generated code: its Julia type `typ` (widened), its representation `kind`,
its leaves (a local, or a constant instruction, per Wasm value of the layout of `typ`),
the value itself when it is known at compile time, and for a pointer, its origin.
"""
struct CGVal
    typ::Any
    kind::Kind
    leaves::Vector{LeafVal}
    constant::Union{Nothing,Some{Any}}
    origin::Union{Nothing,PtrOrigin}
end

CGVal(@nospecialize(typ), kind::Kind, leaves::AbstractVector) =
    CGVal(typ, kind, convert(Vector{LeafVal}, leaves), nothing, nothing)
CGVal(@nospecialize(typ), kind::Kind, leaves::AbstractVector, constant) =
    CGVal(typ, kind, convert(Vector{LeafVal}, leaves), constant, nothing)

"The ghost value `v` of type `T`."
ghost(@nospecialize(T), @nospecialize(v)) = CGVal(T, Ghost, LeafVal[], Some{Any}(v))

"The value of code that never returns."
bottom() = CGVal(Union{}, Bottom, LeafVal[], nothing)

isconstant(v::CGVal) = v.constant !== nothing
constant_value(v::CGVal) = something(v.constant)

function Base.show(io::IO, v::CGVal)
    print(io, "CGVal(", v.kind, ", ", v.typ)
    isconstant(v) && (print(io, ", constant="); show(io, constant_value(v)))
    print(io, ", ", v.leaves, ")")
end

"""
    MultiVal

The results of a structured control flow operation (an `if` or a loop), read with
`getfield(op, i)`.
"""
struct MultiVal
    vals::Vector{CGVal}
end
