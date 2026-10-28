# Programs inferred into a package image, for what differs from code inferred in the session:
# the patches' `max_args` bumps don't reach code in a package image, only the methods they define.
module PrecompiledPrograms

# `eachindex` over four arrays: Julia 1.13 throws a mismatch through a vararg recursion. Only
# that: the arrays are built from integer ranges (a float range's errors print through a vararg
# `print_to_string`, which in a package image is the same failure for another reason).
function sum4(n::Int)
    a = [Float64(i) for i in 1:n]; b = [2.0i for i in 1:n]; c = [3.0i for i in 1:n]; d = [4.0i for i in 1:n]
    s = 0.0
    @inbounds for i in eachindex(a, b, c, d)
        s += a[i] * b[i] + c[i] - d[i]
    end
    return s
end
precompile(sum4, (Int,))

end
