# Solve natively with each linear solver: counts, times, and agreement with the dense LU's.
#   julia +1.13 --project=. native.jl
include("model.jl")

for k in Int32(1):Int32(3)
    n = bz_solve(k, 1.0, 3.0, 0.02, 1.0)
    t = minimum(@elapsed(bz_solve(k, 1.0, 3.0, 0.02, 1.0)) for _ in 1:5) * 1000
    dev = maximum(abs(bz_value(k, i, j, c) - bz_value(Int32(1), i, j, c))
                  for i in Int32(1):Int32(n), j in Int32(1):Int32(N), c in Int32(1):Int32(2))
    println(rpad(SOLVERS[k], 24), "points ", n, ", steps ", bz_stat(k, Int32(1)), "+", bz_stat(k, Int32(2)),
            ", W ", bz_stat(k, Int32(3)), ", solves ", bz_stat(k, Int32(5)), ", ",
            round(t, digits=2), " ms, max |Δ| vs LU ", dev, ", checksum ",
            sum(bz_value(k, i, j, Int32(1)) + 2 * bz_value(k, i, j, Int32(2)) for i in Int32(1):Int32(n), j in Int32(1):Int32(N)))
end
