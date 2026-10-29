# Functions of types at run time (see `reflection.jl`): `map_type(f, T)` is `f(T)`, which
# the code generator compiles to a table of `f` over the types of the module.

@noinline map_type(f::F, @nospecialize(T)) where {F} = f(T)::Type

"The type a value shown in a context of `typeinfo` `T` is printed as (`nonnothing_nonmissing_typeinfo`)."
nonnothing_nonmissing(@nospecialize(T)) = T isa Type ? Base.nonmissingtype(Base.nonnothingtype(T)) : Any

"""
    tuple_as(x, C)

The tuple `x` of a type of unknown length as an object of the concrete tuple type `C`, if it
is one, else `nothing`: a case of the conversion of a tuple to an object (`tuple_canon_func!`).
"""
@noinline function tuple_as(x, ::Type{C}) where {C}
    r = Ref{Any}(nothing)
    x isa C && (r[] = x::C)
    return r[]
end

"""
    tuple_any(x)

The tuple `x` of a type of unknown length as a `Tuple` (its elements as objects): the object
it is where the module does not have its concrete type (see `tuple_canon_func!`).
"""
@noinline tuple_any(x) = Ref{Tuple}(x)[]

"""
    tuple_from(x, C, S)

The tuple object `x`, of the tuple type `C` (concrete, or `Tuple`), as a value of the tuple
type of unknown length `S`: a case of the conversion of an object to such a tuple
(`tuple_from_func!`). (The types by `Val`s: a `Type` of an abstract one is not a constant of
the code.)
"""
@noinline tuple_from(@nospecialize(x), ::Val{C}, ::Val{S}) where {C,S} = Ref{S}(x::C)[]

"""
    tuple_objectid(x, S)

`objectid` of the tuple `x`, of a type the module does not have, an object of `S` (`Tuple`,
see `tuple_canon_func!`): of its elements, as of a tuple of a known type, from `S`'s id for
that type's hash.
"""
@noinline function tuple_objectid(@nospecialize(x), ::Val{S}) where {S}
    t = x::S
    h = objectid(S)
    for i in 1:length(t)
        h = bitmix(h, objectid(t[i]))
    end
    return h
end

"""
    types_equal(a, b)

`jl_types_equal(a, b)`: whether the types `a` and `b` are equal, as subtypes of each other
(`<:` of the module's types is a table, see `reflection.jl`). `Vararg`s, which are not types,
are equal as the C runtime compares them: of the same length (or both of no length) and of
the same element type (`===`; a bare `Vararg`'s is `Any`). A `Vararg` and a type are not.
(The C runtime also finds `Vararg`s equal whose element types differ only in the names of
type variables, `Vararg{Tuple{T,T} where T}` and `Vararg{Tuple{S,S} where S}`: here they are
not, as the fields of type objects are not read at run time.)
"""
function types_equal(@nospecialize(a), @nospecialize(b))
    a === b && return Int32(1)
    if a isa Core.TypeofVararg || b isa Core.TypeofVararg
        a isa Core.TypeofVararg || return Int32(0)
        b isa Core.TypeofVararg || return Int32(0)
        va, vb = a::Core.TypeofVararg, b::Core.TypeofVararg
        isdefined(va, :N) == isdefined(vb, :N) || return Int32(0)
        isdefined(va, :N) && !(getfield(va, :N) === getfield(vb, :N)) && return Int32(0)
        Ta = isdefined(va, :T) ? getfield(va, :T) : Any
        Tb = isdefined(vb, :T) ? getfield(vb, :T) : Any
        return Int32(Ta === Tb)
    end
    return Int32(((a <: b)::Bool && (b <: a)::Bool)::Bool)
end

"""
The error of `typeof` of a tuple whose concrete type is not one of the module's (see
`reflection.jl`). (Julia's `typeof` does not throw, so inference may have removed the
handlers around it: the message is also written to `Core.stderr` before the error.)
"""
@noinline function throw_typeof_unknown()
    msg = "WasmCodegen: typeof of a tuple whose concrete type the module does not have (no types are made at run time)"
    Core.println(Core.stderr, msg)
    error(msg)
end
