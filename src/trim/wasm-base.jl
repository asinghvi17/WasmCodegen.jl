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
    end
end
