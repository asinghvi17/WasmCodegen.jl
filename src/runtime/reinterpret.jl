# Reinterpreting isbits values (`reinterpret(NTuple{4,UInt8}, x::UInt32)`): Base copies
# their bytes through pointers to `Ref`s, after computing their padding by reflection; the
# pseudo-runtime's `Base._reinterpret` (`trim/wasm-base.jl`) computes the padding at compile
# time and calls `reinterpret_bits`, which the code generator compiles itself.

"""
    reinterpret_bits(Out, x)

The bytes of the isbits value `x` as a value of the isbits type `Out` of the same size and
padding. A primitive of the code generator (which rearranges the leaves of `x`); natively,
a copy of the bytes, as Base makes it.
"""
@noinline function reinterpret_bits(::Type{Out}, x::In) where {Out,In}
    in = Ref{In}(x)
    out = Ref{Out}()
    GC.@preserve in out begin
        Base.memcpy(Base.unsafe_convert(Ptr{Out}, out), Base.unsafe_convert(Ptr{In}, in), sizeof(Out))
    end
    return out[]
end

# the layouts of isbits types, by reflection, evaluated at compile time
Base.@assume_effects :foldable packedsize(::Type{T}) where {T} = Base.packedsize(T)
Base.@assume_effects :foldable struct_subpadding(::Type{Out}, ::Type{In}) where {Out,In} =
    Base.struct_subpadding(Out, In)
