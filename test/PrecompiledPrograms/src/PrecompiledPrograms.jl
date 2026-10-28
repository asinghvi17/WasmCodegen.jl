# Programs inferred into a package image, for what differs from code inferred in the session:
# the patches' `max_args` bumps don't reach code in a package image, only the methods they define.
module PrecompiledPrograms

# `eachindex` over four arrays: Julia 1.13 throws a mismatch through a vararg recursion
function sum4(n::Int)
    a = collect(1.0:n); b = 2a; c = 3a; d = 4a
    s = 0.0
    @inbounds for i in eachindex(a, b, c, d)
        s += a[i] * b[i] + c[i] - d[i]
    end
    return s
end
precompile(sum4, (Int,))

end
