# Programs from JuliaC.jl's tests (test/lib_project, test/untrimmable.jl,
# test/TrimmabilityProject): what juliac --trim=safe compiles, compiled to Wasm. Entry points
# that print are adapted to return their values until the runtime has output, and
# LinearAlgebra is left out for now.

module JuliaCPrograms

# lib_project: reshape with `Colon()` (which once needed `show(::IO, ::Colon)`)
function jc_add_one(x::Cint)::Cint
    m = reshape([x, x, x, x], :, 2)
    return m[1, 1] + 1
end

# untrimmable.jl: dynamic dispatch through an inference barrier
function untrimmable(n::Int)
    x = Base.inferencebarrier(n)
    return x + x
end

# TrimmabilityProject: concrete type dispatch
struct Square
    side::Float64
end
struct Circle
    radius::Float64
end
area(s::Square) = s.side^2
area(c::Circle) = pi * c.radius^2
sum_areas() = area(Circle(1)) + area(Square(2))

# TrimmabilityProject: the reductions of its main, on a deterministic vector
function reductions(n::Int)
    arr = [sin(i * 1.3) + 1.0 for i in 1:n]
    sorted_arr = sort(arr)
    tot = sum(sorted_arr) + prod(sorted_arr)
    a = any(x -> x > 0, sorted_arr)
    b = all(x -> x >= 0, sorted_arr)
    c = map(x -> x^2, sorted_arr)
    d = mapreduce(x -> x^2, +, sorted_arr)
    return tot + a + b + sum(c) + d
end

# TrimmabilityProject: nested reductions with `init` (norm(_, 1) as a sum: no LinearAlgebra)
function nested_reductions()
    v = [1.0, 0.0, 2.0]
    counted = maximum(count(!iszero, v .* i) for i in 1:3)
    summed = sum(x -> sum(y -> y * x, v; init=0.0), v; init=0.0)
    normed = maximum(sum(abs, v .* i) for i in 1:3)
    return (counted, summed, normed)
end

# TrimmabilityProject: concatenations (on deterministic arrays: `rand` needs the runtime)
mat(n, m, s) = [sin(s + i + 10j) for i in 1:n, j in 1:m]
vecv(n, s) = [cos(s + i) for i in 1:n]
function cats()
    a = hcat(vecv(3, 1), vecv(3, 2), vecv(3, 3))
    b = [mat(3, 3, 1) mat(3, 3, 2) mat(3, 3, 3)]
    c = vcat(mat(3, 3, 4), mat(3, 3, 5))
    d = [vecv(3, 6); vecv(3, 7)]
    e = hvcat((2, 2), mat(3, 2, 8), mat(3, 4, 9), mat(1, 2, 10), mat(1, 4, 11))
    f = cat(vecv(3, 12), vecv(3, 13); dims=1)
    g = stack([vecv(3, 14), vecv(3, 15), vecv(3, 16)])
    h = repeat(mat(2, 3, 17), 2, 3)
    return a[1] + b[1] + c[end] + d[end] + e[1] + f[end] + g[end] + h[end] + size(h, 2)
end


# AppProject / MathApp: printing to Core.stdout
function app_main()::Cint
    println(Core.stdout, "Fast compilation test!")
    return 0
end
function math_main(x::Float64)::Cint
    println(Core.stdout, "sin(", x, ") = ", sin(x))
    return 0
end

end
