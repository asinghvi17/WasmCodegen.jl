# The pseudo-runtime's Random: the vector operations of Random's bulk generator
# (XoshiroSimd), which are LLVM IR (`llvmcall`), as the same operations on each element of
# their tuples, so that the stream of numbers is the same as natively. Applied with
# juliac's trim patches (see `patches.jl`), when Random is loaded.

let Random = Base.maybe_root_module(Base.PkgId(
        Base.UUID("9a3f8284-a2c9-5f02-9a11-845980a1fd5c"), "Random"))
    if Random !== nothing
        @eval Random.XoshiroSimd begin
            # LLVM's lshr: shifts of 64 or more are poison there, Base's give zero
            @inline _lshr(x::UInt64, y::Int64) = x >>> y
        end
        for N in (4, 8, 16)
            VT = NTuple{N,VecElement{UInt64}}
            @eval Random.XoshiroSimd begin
                @inline _rotl45(x::$VT) = map(e -> VecElement(_rotl45(e.value)), x)
                @inline _rotl23(x::$VT) = map(e -> VecElement(_rotl23(e.value)), x)
                @inline _shl17(x::$VT) = map(e -> VecElement(_shl17(e.value)), x)
                @inline _plus(x::$VT, y::$VT) = map((a, b) -> VecElement(_plus(a.value, b.value)), x, y)
                @inline _xor(x::$VT, y::$VT) = map((a, b) -> VecElement(_xor(a.value, b.value)), x, y)
                @inline _and(x::$VT, y::$VT) = map((a, b) -> VecElement(_and(a.value, b.value)), x, y)
                @inline _or(x::$VT, y::$VT) = map((a, b) -> VecElement(_or(a.value, b.value)), x, y)
                @inline _lshr(x::$VT, y::Int64) = map(e -> VecElement(_lshr(e.value, y)), x)
                @inline _bits2float(x::$VT, ::Type{Float64}) = map(e -> VecElement(_bits2float(e.value, Float64)), x)
                @inline _bits2float(x::$VT, ::Type{Float32}) = map(e -> VecElement(_bits2float(e.value, Float32)), x)
                @inline _bits2float(x::$VT, ::Type{Float16}) = map(e -> VecElement(_bits2float(e.value, Float16)), x)
            end
        end
    end
end
