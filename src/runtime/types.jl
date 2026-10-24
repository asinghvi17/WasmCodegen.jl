# Functions of types at run time (see `reflection.jl`): `map_type(f, T)` is `f(T)`, which
# the code generator compiles to a table of `f` over the types of the module.

@noinline map_type(f::F, @nospecialize(T)) where {F} = f(T)::Type

"The type a value shown in a context of `typeinfo` `T` is printed as (`nonnothing_nonmissing_typeinfo`)."
nonnothing_nonmissing(@nospecialize(T)) = T isa Type ? Base.nonmissingtype(Base.nonnothingtype(T)) : Any
