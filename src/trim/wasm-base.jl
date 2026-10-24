# The pseudo-runtime's patches of Base: code that natively reflects on types or memory at run
# time, made to do so at compile time. Applied with juliac's trim patches (see `patches.jl`).

let Runtime = WasmCodegen.Runtime
    @eval Base begin
        # reinterpreting isbits values: by their leaves (see `runtime/reinterpret.jl`)
        @inline function _reinterpret(::Type{Out}, x::In) where {Out, In}
            isbitstype(Out) || throw(ArgumentError("Target type for `reinterpret` must be isbits"))
            isbitstype(In) || throw(ArgumentError("Source type for `reinterpret` must be isbits"))
            inpackedsize = $(Runtime.packedsize)(In)
            outpackedsize = $(Runtime.packedsize)(Out)
            inpackedsize == outpackedsize ||
                throw(ArgumentError(LazyString("Packed sizes of types ", Out, " and ", In,
                    " do not match; got ", outpackedsize, " and ", inpackedsize, ", respectively.")))
            if $(Runtime.struct_subpadding)(Out, In)
                return $(Runtime.reinterpret_bits)(Out, x)
            else
                return _reinterpret_padding(Out, x)
            end
        end
        # a call in the latest world (to keep it unspecialized natively): a direct call, which
        # specializes it on the type, so its reflection is done at compile time
        _typeinfo_implicit(@nospecialize(T)) = typeinfo_implicit(T)::Bool
        # printing a type: juliac's (which reflects on the type, see juliac-trim-base.jl),
        # made a foldable function of the type, so that inference computes the name of a
        # type known at compile time (as a Symbol: a String is not kept as a constant)
        Base.@assume_effects :foldable _type_name(@nospecialize(T::Type)) = Symbol(sprint(_show_type, T))
        show(io::IO, T::Type) = print(io, _type_name(T))
        # (`typesplit` reflects on and makes types: a table of the module's types instead)
        nonnothing_nonmissing_typeinfo(io::IO) =
            $(Runtime.map_type)($(Runtime.nonnothing_nonmissing), get(io, :typeinfo, Any))
        function _show_type_param(io::IO, @nospecialize(p))
            if p isa Int
                show(io, p)
            elseif p isa Type
                _show_type(io, p)
            elseif p isa Symbol
                print(io, ":")
                print(io, p)
            elseif p isa TypeVar
                print(io, p.name)
            else
                print(io, "?")
            end
        end
        function _show_type(io::IO, @nospecialize(T::Type))
            if T isa DataType
                print(io, T.name.name)
                if T !== T.name.wrapper && length(T.parameters) > 0
                    print(io, "{")
                    first = true
                    for p in T.parameters
                        first || print(io, ", ")
                        first = false
                        _show_type_param(io, p)
                    end
                    print(io, "}")
                end
            elseif T isa Union
                print(io, "Union{")
                _show_type_param(io, T.a)
                print(io, ", ")
                _show_type_param(io, T.b)
                print(io, "}")
            elseif T isa UnionAll
                _show_type(io, T.body::Type)
                print(io, " where ")
                print(io, T.var.name)
            end
        end
    end
end
