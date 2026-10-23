# Random: the default task-local RNG (seeded by the host's entropy at start), and Xoshiro
# generators seeded by value, whose streams must be the native ones (seeding hashes with
# SHA-256; the bulk generator's vector code is the pseudo-runtime's, `trim/wasm-random.jl`).

using Random

rand_default() = rand()
rand_vector(n::Int) = (v = rand(n); (minimum(v), maximum(v), length(v)))
rand_seeded(s::Int) = rand(Xoshiro(s))
rand_seeded_vector(s::Int, n::Int) = foldl(+, rand(Xoshiro(s), n))
rand_range(s::Int, n::Int) = sum(rand(Xoshiro(s), 1:100, n))
rand_bytes(s::Int, n::Int) = sum(Int, rand(Xoshiro(s), UInt8, n))
rand_bools(s::Int, n::Int) = count(rand(Xoshiro(s), Bool, n))
function rand_mixed(s::Int)
    rng = Xoshiro(s)
    a = rand(rng, Float32, 33)
    b = randn(rng, 5)
    return (foldl(+, a), foldl(+, b), rand(rng, UInt64))
end

@testset "random" begin
    x = wasm_run(wcompile(rand_default, ()), "rand_default"; rettype=Float64)
    @test x isa Float64 && 0 <= x < 1
    lo, hi, n = wasm_run(wcompile(rand_vector, (Int,)), "rand_vector", 100; rettype=Tuple{Float64,Float64,Int})
    @test 0 <= lo <= hi < 1 && n == 100 && lo != hi
    @wtest rand_seeded(1234)
    @wtest rand_seeded_vector(1234, 40)
    @wtest rand_range(7, 30)
    @wtest rand_bytes(7, 90)
    @wtest rand_bytes(7, 5)
    @wtest rand_bools(3, 700)
    @wtest rand_mixed(42)
end
