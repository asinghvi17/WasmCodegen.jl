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

# tuples with union elements: inline, boxed as one of their concrete types
function union_tuples(i::Int)
    t = (i > 1, findfirst(==(i), [1, 3, 5]), i * 1.5)
    v = Any[t, 1]
    u = v[1]::Tuple{Bool,Union{Nothing,Int},Float64}
    w = Tuple{Bool,Union{Nothing,Int},Float64}[t, (true, nothing, 0.5)]
    (t[2] === nothing ? -1 : t[2]::Int, u === t, u[3], w[1][2] === t[2], t isa Tuple{Bool,Int,Float64},
     w[2][2] === nothing, any(>(i), 1:5), all(<(i), 1:5))
end

# an if yielding `nothing` itself on one side and a value of a union on the other
@noinline maybe_vec(i::Int) = i > 2 ? [1.0, 2.0 * i] : nothing
function nothing_merge(i::Int)
    x = i > 0 ? maybe_vec(i) : nothing
    y = i > 1 ? nothing : maybe_vec(i + 3)
    (x === nothing ? -1.0 : sum(x), y === nothing ? -2.0 : sum(y))
end

# LLVM intrinsics through `ccall(..., llvmcall, ...)` on vectors (tuples of VecElements), loaded
# and stored through pointers (LinearSolve's blocked LU kernel); exact products, so that fusing
# the multiply-add or not gives the same result
const V4 = NTuple{4,VecElement{Float64}}
vfma(a::V4, b::V4, c::V4) = ccall("llvm.fmuladd.v4f64", llvmcall, V4, (V4, V4, V4), a, b, c)
function vector_fma(n::Int)
    v = collect(1.0:8.0) .* n
    GC.@preserve v begin
        p = pointer(v)
        a = unsafe_load(Ptr{V4}(p))
        b = unsafe_load(Ptr{V4}(p + 32))
        unsafe_store!(Ptr{V4}(p + 32), vfma(a, b, ntuple(_ -> VecElement(0.5), 4)))
    end
    return ntuple(i -> v[i], Val(8))
end

# modules as values (SciMLLogging passes the logging module along)
@noinline pick_module(i::Int) = i > 0 ? Base : Core
modules(i::Int) = (checksum(string(nameof(pick_module(i)))), pick_module(i) === Base, pick_module(i) === pick_module(-i))

# paths: Base splits them with regular expressions, here by their bytes
const PATHS = ("/home/user/file.jl", "a/b/", "//x", "name.tar.gz", ".bashrc", "dir/..", "", "é/ü.txt")
paths(i::Int) = (p = PATHS[i]; checksum(join((basename(p), dirname(p), splitext(p)..., splitdir(p)...), "|")) + isdirpath(p))
clock(i::Int) = (t = time_ns(); s = sum(1:i); time_ns() >= t && s >= 0)

# IdDict: identity hash tables (the C runtime's), built at run time and at compile time (laid
# out natively by the same hash)
const IDD = IdDict{Any,Int}(:a => 1, "s" => 2, 3 => 3, 2.5 => 4, (1, 2) => 5)
function iddicts(n::Int)
    d = IdDict{Any,Int}()
    ks = [Int[k] for k in 1:n]  # mutable keys: by identity
    for (k, v) in enumerate(ks)
        d[v] = k
    end
    d[:sym] = -1; d["str"] = -2; d[2.5] = -3; d[nothing] = -4
    s = sum(k -> d[k], ks; init=0)
    n > 0 && delete!(d, ks[1])
    delete!(d, nothing)
    return (length(d), s, get(d, [1], 0), n > 0 && haskey(d, ks[1]), d[:sym] + d["str"] + d[2.5],
            get(IDD, :a, 0) + get(IDD, "s", 0) + get(IDD, 3, 0) + get(IDD, 2.5, 0) + get(IDD, (1, 2), 0),
            sum(values(d)), haskey(d, nothing))
end

# deepcopy: of immutable structs (the generic method: their fields, through `jl_new_structv`),
# arrays and memory (through an IdDict)
struct Pair3
    a::Vector{Int}
    b::Tuple{Float64,String}
    c::Vector{Int}
end
function deepcopies(n::Int)
    v = collect(1:n)
    p = Pair3(v, (1.5, "x"), v)
    q = deepcopy(p)
    q.a[1] = -1
    return (p.a[1], q.c[1], q.a === q.c, q.a === p.a, q.b === p.b, sum(deepcopy([v, v])[2]))
end

# locks and atomic fields, in a program of one task (a lock is never contended)
const RLOCK = ReentrantLock()
const SLOCK = Threads.SpinLock()
mutable struct Atomics
    @atomic n::Int
    @atomic s::Union{Nothing,String}
end
function locks(i::Int)
    s = Ref(0)
    lock(RLOCK) do
        lock(() -> (s[] += i), RLOCK)  # (reentrant)
    end
    lock(SLOCK); s[] += 1; unlock(SLOCK)
    c = Atomics(i, nothing)
    old = @atomicswap c.n = 5
    r = @atomicreplace c.n 5 => 7
    r2 = @atomicreplace c.n 5 => 9
    m = @atomic c.n += 3
    once = @atomiconce c.s = "x"
    return (s[], old, r.success, r2.success, r2.old, c.n, m, islocked(RLOCK),
            trylock(RLOCK) && (unlock(RLOCK); true), once, c.s === "x")
end

# Threads.Atomic (Julia 1.12 writes its operations as LLVM IR)
function atomics(i::Int)
    a = Threads.Atomic{Int}(i)
    Threads.atomic_add!(a, 3); Threads.atomic_sub!(a, 1)
    x = Threads.atomic_cas!(a, i + 2, 10)
    y = Threads.atomic_xchg!(a, 4)
    Threads.atomic_max!(a, 7); Threads.atomic_min!(a, 5); Threads.atomic_or!(a, 8)
    f = Threads.Atomic{Float64}(1.5)
    Threads.atomic_add!(f, 2.0)
    z = Threads.atomic_cas!(f, 3.5, -1.0)
    return (a[], x, y, f[], z)
end

@testset "coverage" begin
    for i in 0:2
        @wtest atomics(i)
    end
    for i in 0:2
        @wtest locks(i)
    end
    for n in 1:3
        @wtest deepcopies(n)
    end
    for n in (0, 1, 5, 40, 300)
        @wtest iddicts(n)
    end
    for n in 0:2
        @wtest vector_fma(n)
    end
    for i in -1:1
        @wtest modules(i)
    end
    for i in eachindex(PATHS)
        @wtest paths(i)
    end
    @wtest clock(3)
    for i in 0:4
        @wtest nothing_merge(i)
    end
    for i in 0:5
        @wtest union_tuples(i)
    end
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
