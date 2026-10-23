# Values in generated code.

"A leaf of a value: a local of the function, or one instruction that pushes a constant."
const LeafVal = Union{Int,Inst}

"""
    CGVal

A value in generated code: its Julia type `typ` (widened), its representation `kind`,
its leaves (a local, or a constant instruction, per Wasm value of the layout of `typ`),
and the value itself when it is known at compile time.
"""
struct CGVal
    typ::Any
    kind::Kind
    leaves::Vector{LeafVal}
    constant::Union{Nothing,Some{Any}}
end

CGVal(@nospecialize(typ), kind::Kind, leaves::Vector{LeafVal}) = CGVal(typ, kind, leaves, nothing)

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
