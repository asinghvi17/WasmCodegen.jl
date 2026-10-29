# `typeof` of a value of an abstract type (a table of the module's type objects by type id,
# reflection.jl `typeof_any!`), as Base.TOML's parse_array uses it to type a parsed array.

struct TypeofAnyS
    a::Int
end
mutable struct TypeofAnyM
    x::Any
end

# the elements of the vector `n`, of several types, behind `Any`
function typeof_any_values(n::Int)
    v = Any[n, "s", 2.5, nothing, :sym, Int[n], Dict("k" => n), (n, "t"), SubString("abc", 2),
            TypeofAnyS(n), TypeofAnyM(n), true, 'c', UInt8(n), v"1.2.3", Int32(n)]
    return v
end

# as parse_array: the type of all elements if they have one, else Any
function array_type(v::Vector{Any})
    T = !isempty(v) ? typeof(v[1]) : Union{}
    for el in v
        if typeof(el) != T
            T = Any
            break
        end
    end
    return T
end

# the type of each value, by identity with known types, and by `<:` and `==`
function typeof_any_codes(n::Int)
    v = typeof_any_values(n)
    codes = 0
    for x in v
        T = typeof(x)
        k = T === Int ? 1 : T === String ? 2 : T === Float64 ? 3 : T === Nothing ? 4 : T === Symbol ? 5 :
            T === Vector{Int} ? 6 : T === Dict{String, Int} ? 7 : T === Tuple{Int, String} ? 8 :
            T === SubString{String} ? 9 : T === TypeofAnyS ? 10 : T === TypeofAnyM ? 11 : T === Bool ? 12 :
            T === Char ? 13 : T === UInt8 ? 14 : T === VersionNumber ? 15 : T === Int32 ? 16 : 0
        codes = codes * 31 + k
        codes = codes * 3 + (T <: Number) + 2 * (T == typeof(v[1]))
    end
    return codes
end
# as parse_array, on arrays of one type and of mixed types (codes of the results; the
# values behind Any pushed, as `Any[a, b]` of them makes a Tuple{Any, Any}, not compiled yet)
function typeof_any_kinds(n::Int)
    v = typeof_any_values(n)
    return (array_type(Any[1, 2, n]) === Int) + 2 * (array_type(Any["a", "b"]) === String) +
           4 * (array_type(Any[1, "a"]) === Any) + 8 * (array_type(Any[]) === Union{}) +
           16 * (array_type(push!(push!(Any[], v[2]), v[9])) === Any) + 32 * (array_type(Any[Dict("a" => 1), Dict("b" => n)]) === Dict{String, Int})
end
# a type from a value behind Any, used to make a vector of it (as parse_array does)
function typeof_any_typed(n::Int)
    v = Any[string(k) for k in 1:n]
    T = array_type(v)
    T === String || return -1
    new = Vector{String}(undef, length(v))
    for i in eachindex(v)
        new[i] = v[i]::String
    end
    return sum(length, new)
end

@testset "typeof of abstract values" begin
    @wtest typeof_any_codes(3)
    @wtest typeof_any_codes(250)
    @wtest typeof_any_kinds(4)
    @wtest typeof_any_typed(12)
end

# Vararg arguments of jl_types_equal, typeof of tuples of abstract-typed elements
@noinline typeof_any_id(x) = x
# 1: a tuple whose concrete type the module does not have (an object of `Tuple`): in Wasm a
# failure with a message (natively its type; `typeof` does not throw, so it cannot be caught)
function typeof_unknown_tuple(n::Int)
    x = typeof_any_id(Any[tuple(collect(1:n)...)])[1]
    return typeof_any_id(typeof(x)) <: Tuple
end
# 2: a type known only as a value's (boxed behind Any), mapped by a function of types
struct TypeofAnyMapOnly
    x::Int
end
typeof_any_map(n::Int) = (T = typeof(typeof_any_id(Any[TypeofAnyMapOnly(n)])[1]);
                          WasmCodegen.Runtime.map_type(WasmCodegen.Runtime.nonnothing_nonmissing, T) === T)
# 3: jl_types_equal of Varargs (not types), as the C runtime's
const TYPEOF_ANY_VARARGS = Any[Vararg{Int}, Vararg{Int}, Vararg{Real}, Vararg{Int, 2}, Vararg{Int, 3}, Int, Tuple{Vararg{Int}},
                               Vararg, Vararg{Any}, Vararg{Any, 2}, Vararg{Tuple{Union{Int,Nothing}}},
                               Vararg{Union{Tuple{Int},Tuple{Nothing}}}, Tuple{Union{Int,Nothing}},
                               Union{Tuple{Int},Tuple{Nothing}}, Vararg{Tuple{T,T} where T},
                               Vararg{Tuple{T,T} where T<:Integer}, Vararg{Tuple{S,T} where {S,T}}]
typeof_any_vararg_eq(i::Int, j::Int) =
    ccall(:jl_types_equal, Cint, (Any, Any), TYPEOF_ANY_VARARGS[i], TYPEOF_ANY_VARARGS[j])

@testset "typeof and jl_types_equal: Varargs and tuples" begin
    @test typeof_unknown_tuple(7)
    let c = wcompile(typeof_unknown_tuple, (Int,)), got = wasm_run(c, "typeof_unknown_tuple", 7; rettype = Bool)
        @test got isa Tuple && got[1] === :trap
        @test occursin("typeof of a tuple whose concrete type the module does not have", LAST_OUTPUT[])
    end
    @wtest typeof_any_map(1)
    for i in 1:length(TYPEOF_ANY_VARARGS), j in 1:length(TYPEOF_ANY_VARARGS)
        @wtest typeof_any_vararg_eq(i, j)
    end
    # (the runtime's jl_types_equal against the C runtime's, natively)
    for a in TYPEOF_ANY_VARARGS, b in TYPEOF_ANY_VARARGS
        @test WasmCodegen.Runtime.types_equal(a, b) == ccall(:jl_types_equal, Cint, (Any, Any), a, b)
    end
    # (element types that differ only in the names of type variables: see `types_equal`)
    @test_broken WasmCodegen.Runtime.types_equal(Vararg{Tuple{T,T} where T}, Vararg{Tuple{S,S} where S}) == 1
end
