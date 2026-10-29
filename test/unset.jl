# Unsetting inline elements that hold references: Base's `_unsetindex!` (`deleteat!`,
# `resize!`, `empty!`, copying an undefined element over an assigned one) stores null
# pointers into them; the element becomes undefined, as natively (`isassigned` false). Two
# layouts: a box per element (SubString, Tuple{String,Int}) and a reference per leaf
# (Tuple{String,String}, UnionRefs). In Wasm the unset is `Runtime.unset_element!` (the
# patch `trim/wasm-memory.jl`); a lone null store into such an element stays unsupported.
function unset_probe(::Type{T}, mk) where {T}
    v = Vector{T}(undef, 3)
    v[1] = mk(1); v[2] = mk(2); v[3] = mk(3)
    deleteat!(v, [1])
    a = isassigned(v, 1) && isassigned(v, 2)
    resize!(v, 1); resize!(v, 3)
    b = (isassigned(v, 1), isassigned(v, 2), isassigned(v, 3))
    dst = Memory{T}(undef, 2)
    dst[1] = mk(4); dst[2] = mk(5)
    copyto!(dst, Memory{Union{Nothing,T}}(undef, 2))  # (a different element type: element by element)
    c = (isassigned(dst, 1), isassigned(dst, 2))
    w = [mk(k) for k in 1:5]
    popfirst!(w); pop!(w); deleteat!(w, 2)
    empty!(w); sizehint!(w, 4); resize!(w, 2)
    d = (isassigned(w, 1), isassigned(w, 2))
    return (a, b, c, d, length(w))
end
unset_substring(n::Int) = unset_probe(SubString{String}, k -> SubString(string("ab", k + n), 2))
unset_tuple_si(n::Int) = unset_probe(Tuple{String,Int}, k -> (string(k + n), k))
unset_tuple_ss(n::Int) = unset_probe(Tuple{String,String}, k -> (string(k + n), "x"))

struct UnsetUnionRefs
    x::Union{Nothing,Int32}
    y::Any
end
unset_unionrefs(n::Int) = unset_probe(UnsetUnionRefs, k -> UnsetUnionRefs(Int32(k + n), "alive"))

# single null stores into an inline element (not an unset): to be rejected, not miscompiled
function clear_pointer_field(n::Int)
    m = Memory{Tuple{Ptr{Cvoid},Int}}(undef, 1)
    m[1] = (Ptr{Cvoid}(UInt(n)), n)
    GC.@preserve m unsafe_store!(Ptr{Ptr{Cvoid}}(pointer(m)), C_NULL)
    return (m[1][1] == C_NULL, m[1][2])
end
function clear_numeric_word(n::Int)
    m = Memory{Tuple{String,Int}}(undef, 1)
    m[1] = ("alive", n)
    GC.@preserve m unsafe_store!(Ptr{Ptr{Cvoid}}(pointer(m) + 8), C_NULL)
    return isassigned(m, 1)
end
function clear_union_word(n::Int)
    m = Memory{UnsetUnionRefs}(undef, 1)
    m[1] = UnsetUnionRefs(Int32(n), "alive")
    GC.@preserve m unsafe_store!(Ptr{Ptr{Cvoid}}(pointer(m)), C_NULL)
    return isassigned(m, 1)
end

@testset "unsetting inline elements" begin
    # the oracle is Base's own `_unsetindex!`: in a fresh Julia 1.13.2 without the patches,
    # each probe returns this (checked when written; the probes run natively here with the
    # patch, whose native `unset_element!` does Base's stores)
    UNPATCHED = (true, (true, false, false), (false, false), (false, false), 2)
    for f in (unset_substring, unset_tuple_si, unset_tuple_ss, unset_unionrefs)
        @test f(1) == UNPATCHED
    end
    @wtest unset_substring(1)
    @wtest unset_tuple_si(1)
    @wtest unset_tuple_ss(1)
    @wtest unset_unionrefs(1)
    for f in (clear_pointer_field, clear_numeric_word, clear_union_word)
        @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(f, (Int,))
    end
end
