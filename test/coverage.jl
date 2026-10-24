# Base functionality found missing by sweeping WasmTarget.jl's catalogue of operations (and
# programs beyond it): results reduced to a checksum of their bytes

checksum(s::String) = foldl((h, b) -> h * 31 + b, codeunits(s); init=UInt64(length(s)))

const CASE_STRS = ("hello World", "αβγ ünïcödé", "ǅemal ß", "")
case_upper(i::Int) = checksum(uppercase(CASE_STRS[i]) * lowercase(CASE_STRS[i]) * titlecase(CASE_STRS[i]))
case_chars(i::Int) = (c = ('a', 'É', 'Σ', 'ǅ', '7')[i]; (isuppercase(c), islowercase(c), uppercase(c), lowercase(c)))
padded(i::Int) = checksum(lpad(CASE_STRS[i], 14, '*') * rpad(CASE_STRS[i], 13) * string(textwidth(CASE_STRS[i])))

const NUM_STRS = ("12.5", " -3e2 ", "1e500", "0x1p3", "x", "", "1 x")
parse_float(i::Int) = something(tryparse(Float64, NUM_STRS[i]), -0.5)
parse_float_sub(i::Int) = something(tryparse(Float64, SubString("[" * NUM_STRS[i] * "]", 2, ncodeunits(NUM_STRS[i]) + 1)), -0.5)
parse_float32(i::Int) = something(tryparse(Float32, NUM_STRS[i]), -0.5f0)

half_arith(a::Float64, b::Float64) = (x = Float16(a); y = Float16(b); (x + y, x * y, x / y, x < y, Float64(sqrt(abs(x))), Float32(x)))
half_string(a::Float64) = checksum(string(Float16(a)))

# (`string` of values of at most four types: Julia 1.12 loops over them, a union it splits)
symbol_string(i::Int) = checksum(string(Symbol("sym", i)) * string(:abc, i, 'c', 1.5) * string(nothing))
type_string(i::Int) = checksum(string(i > 0 ? Int64 : Float64) * string(typeof((i, 2.5))))
shown(i::Int) = checksum(sprint(show, [i, 2]) * repr((i, 1.5, "s")) * repr([1.5, 2.0 * i]) * repr(Float16[i]))

@testset "coverage" begin
    for i in 1:4
        @wtest case_upper(i)
        @wtest padded(i)
    end
    for i in 1:5
        @wtest case_chars(i)
    end
    for i in eachindex(NUM_STRS)
        @wtest parse_float(i)
        @wtest parse_float_sub(i)
        @wtest parse_float32(i)
    end
    for (a, b) in ((1.5, 2.25), (65504.0, 2.0), (1e-6, 3.0), (-0.0, NaN), (0.1, 0.2))
        @wtest half_arith(a, b)
        @wtest half_string(a)
    end
    for i in 0:2
        @wtest symbol_string(i)
        @wtest type_string(i)
        @wtest shown(i)
    end
end
