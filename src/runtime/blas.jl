# BLAS, for what LinearAlgebra calls in libblastrampoline: reference BLAS's algorithms on
# real elements (Float64, Float32), column-major. An array argument is a `MemoryRef` to its
# first element where the code generator knows the memory the pointer points into, else
# the pointer. Results can differ from an optimized BLAS's in their last bits (the order of
# sums), as those of any two BLAS libraries do.

module BLAS

const ArrayArg{T} = Union{MemoryRef{T},Ptr{T}}

# the element `k` (1-based) from the start of an array argument
@inline ld(A::MemoryRef{T}, k::Int) where {T} =
    Core.memoryrefget(Core.memoryrefnew(A, k, false), :not_atomic, false)::T
@inline ld(A::Ptr{T}, k::Int) where {T} = unsafe_load(A, k)
@inline st!(A::MemoryRef{T}, k::Int, v::T) where {T} =
    (Core.memoryrefset!(Core.memoryrefnew(A, k, false), v, :not_atomic, false); nothing)
@inline st!(A::Ptr{T}, k::Int, v::T) where {T} = (unsafe_store!(A, v, k); nothing)

# the position of the `j`-th of `n` elements with increment `inc` (from the end if negative)
@inline pos(j::Int, n::Int, inc::Int) = inc >= 0 ? 1 + (j - 1) * inc : 1 + (n - j) * (-inc)

const N, T_, U, L = UInt8('N'), UInt8('T'), UInt8('U'), UInt8('L')
notrans(t::UInt8) = t == N || t == UInt8('n')
isupper(u::UInt8) = u == U || u == UInt8('u')
isunit(d::UInt8) = d == U || d == UInt8('u')
isleft(s::UInt8) = s == L || s == UInt8('l')

## level 1

function copy!(n::Int, X::ArrayArg{T}, incx::Int, Y::ArrayArg{T}, incy::Int) where {T}
    for j in 1:n
        st!(Y, pos(j, n, incy), ld(X, pos(j, n, incx)))
    end
end

function scal!(n::Int, a::T, X::ArrayArg{T}, incx::Int) where {T}
    incx <= 0 && return
    for j in 1:n
        k = 1 + (j - 1) * incx
        st!(X, k, a * ld(X, k))
    end
end

function dot(n::Int, X::ArrayArg{T}, incx::Int, Y::ArrayArg{T}, incy::Int) where {T}
    s = zero(T)
    for j in 1:n
        s += ld(X, pos(j, n, incx)) * ld(Y, pos(j, n, incy))
    end
    return s
end

# the 2-norm, scaled against overflow and underflow
function nrm2(n::Int, X::ArrayArg{T}, incx::Int) where {T}
    (n < 1 || incx < 1) && return zero(T)
    n == 1 && return abs(ld(X, 1))
    scale, ssq = zero(T), one(T)
    inf = false
    for j in 1:n
        x = ld(X, 1 + (j - 1) * incx)
        # (an infinity makes the norm infinite, unless there is a NaN)
        isinf(x) && (inf = true; continue)
        isnan(x) && return x
        if x != 0
            a = abs(x)
            if scale < a
                ssq = one(T) + ssq * (scale / a)^2
                scale = a
            else
                ssq += (a / scale)^2
            end
        end
    end
    inf && return T(Inf)
    return scale * sqrt(ssq)
end

function asum(n::Int, X::ArrayArg{T}, incx::Int) where {T}
    (n < 1 || incx < 1) && return zero(T)
    s = zero(T)
    for j in 1:n
        s += abs(ld(X, 1 + (j - 1) * incx))
    end
    return s
end

function axpy!(n::Int, a::T, X::ArrayArg{T}, incx::Int, Y::ArrayArg{T}, incy::Int) where {T}
    a == 0 && return
    for j in 1:n
        k = pos(j, n, incy)
        st!(Y, k, ld(Y, k) + a * ld(X, pos(j, n, incx)))
    end
end

function axpby!(n::Int, a::T, X::ArrayArg{T}, incx::Int, b::T, Y::ArrayArg{T}, incy::Int) where {T}
    for j in 1:n
        k = pos(j, n, incy)
        y = b == 0 ? zero(T) : b * ld(Y, k)
        st!(Y, k, a * ld(X, pos(j, n, incx)) + y)
    end
end

# the index of the first element of largest absolute value (0 if none)
function iamax(n::Int, X::ArrayArg{T}, incx::Int) where {T}
    (n < 1 || incx < 1) && return 0
    best, m = 1, abs(ld(X, 1))
    for j in 2:n
        a = abs(ld(X, 1 + (j - 1) * incx))
        a > m && (best = j; m = a)
    end
    return best
end

## matrices

@inline elem(A, lda::Int, i::Int, j::Int) = ld(A, i + (j - 1) * lda)
@inline setelem!(A, lda::Int, i::Int, j::Int, v) = st!(A, i + (j - 1) * lda, v)

# op(A)[i, j] of a general matrix
@inline opelem(A, lda::Int, t::UInt8, i::Int, j::Int) = notrans(t) ? elem(A, lda, i, j) : elem(A, lda, j, i)

# A[i, j] of a symmetric matrix stored in its `uplo` triangle
@inline symelem(A, lda::Int, uplo::UInt8, i::Int, j::Int) =
    (isupper(uplo) ? i <= j : i >= j) ? elem(A, lda, i, j) : elem(A, lda, j, i)

# op(A)[i, j] of a triangular matrix stored in its `uplo` triangle (unit diagonal if `diag`)
@inline function trielem(A::ArrayArg{T}, lda::Int, uplo::UInt8, t::UInt8, diag::UInt8, i::Int, j::Int) where {T}
    notrans(t) || ((i, j) = (j, i))
    i == j && isunit(diag) && return one(T)
    return (isupper(uplo) ? i <= j : i >= j) ? elem(A, lda, i, j) : zero(T)
end
# whether op(A) is upper triangular
opupper(uplo::UInt8, t::UInt8) = isupper(uplo) == notrans(t)

# B := 0, without reading it (BLAS's result where alpha is zero)
function zero_matrix!(m::Int, n::Int, B::ArrayArg{T}, ldb::Int) where {T}
    for j in 1:n, i in 1:m
        setelem!(B, ldb, i, j, zero(T))
    end
end

# y := beta * y (zero where beta is zero, whatever y holds)
function scale_y!(n::Int, beta::T, Y::ArrayArg{T}, incy::Int) where {T}
    beta == 1 && return
    for j in 1:n
        k = pos(j, n, incy)
        st!(Y, k, beta == 0 ? zero(T) : beta * ld(Y, k))
    end
end

## level 2

function gemv!(t::UInt8, m::Int, n::Int, alpha::T, A::ArrayArg{T}, lda::Int,
               X::ArrayArg{T}, incx::Int, beta::T, Y::ArrayArg{T}, incy::Int) where {T}
    (m == 0 || n == 0) && return
    leny, lenx = notrans(t) ? (m, n) : (n, m)
    scale_y!(leny, beta, Y, incy)
    alpha == 0 && return
    for i in 1:leny
        s = zero(T)
        for j in 1:lenx
            s += opelem(A, lda, t, i, j) * ld(X, pos(j, lenx, incx))
        end
        k = pos(i, leny, incy)
        st!(Y, k, ld(Y, k) + alpha * s)
    end
end

function symv!(uplo::UInt8, n::Int, alpha::T, A::ArrayArg{T}, lda::Int, X::ArrayArg{T}, incx::Int,
               beta::T, Y::ArrayArg{T}, incy::Int) where {T}
    n == 0 && return
    scale_y!(n, beta, Y, incy)
    alpha == 0 && return
    for i in 1:n
        s = zero(T)
        for j in 1:n
            s += symelem(A, lda, uplo, i, j) * ld(X, pos(j, n, incx))
        end
        k = pos(i, n, incy)
        st!(Y, k, ld(Y, k) + alpha * s)
    end
end

function trmv!(uplo::UInt8, t::UInt8, diag::UInt8, n::Int, A::ArrayArg{T}, lda::Int,
               X::ArrayArg{T}, incx::Int) where {T}
    # x := op(A) x, in the order that reads each x[j] before it is overwritten
    up = opupper(uplo, t)
    for i in (up ? (1:n) : (n:-1:1))
        s = zero(T)
        for j in (up ? (i:n) : (1:i))
            s += trielem(A, lda, uplo, t, diag, i, j) * ld(X, pos(j, n, incx))
        end
        st!(X, pos(i, n, incx), s)
    end
end

function trsv!(uplo::UInt8, t::UInt8, diag::UInt8, n::Int, A::ArrayArg{T}, lda::Int,
               X::ArrayArg{T}, incx::Int) where {T}
    # op(A) x = b, x overwriting b: back substitution (upper) or forward (lower)
    up = opupper(uplo, t)
    for i in (up ? (n:-1:1) : (1:n))
        s = ld(X, pos(i, n, incx))
        for j in (up ? (i+1:n) : (1:i-1))
            s -= trielem(A, lda, uplo, t, diag, i, j) * ld(X, pos(j, n, incx))
        end
        st!(X, pos(i, n, incx), isunit(diag) ? s : s / trielem(A, lda, uplo, t, diag, i, i))
    end
end

function ger!(m::Int, n::Int, alpha::T, X::ArrayArg{T}, incx::Int, Y::ArrayArg{T}, incy::Int,
              A::ArrayArg{T}, lda::Int) where {T}
    alpha == 0 && return
    for j in 1:n
        y = alpha * ld(Y, pos(j, n, incy))
        for i in 1:m
            setelem!(A, lda, i, j, elem(A, lda, i, j) + ld(X, pos(i, m, incx)) * y)
        end
    end
end

## level 3

# C[i, j] := alpha s + beta C[i, j] (C not read where beta is zero)
@inline function update!(C::ArrayArg{T}, ldc::Int, i::Int, j::Int, alpha::T, s::T, beta::T) where {T}
    c = alpha == 0 ? zero(T) : alpha * s
    beta == 0 || (c += beta * elem(C, ldc, i, j))
    setelem!(C, ldc, i, j, c)
end

function gemm!(ta::UInt8, tb::UInt8, m::Int, n::Int, k::Int, alpha::T, A::ArrayArg{T}, lda::Int,
               B::ArrayArg{T}, ldb::Int, beta::T, C::ArrayArg{T}, ldc::Int) where {T}
    (m == 0 || n == 0) && return
    for j in 1:n, i in 1:m
        s = zero(T)
        if alpha != 0
            for l in 1:k
                s += opelem(A, lda, ta, i, l) * opelem(B, ldb, tb, l, j)
            end
        end
        update!(C, ldc, i, j, alpha, s, beta)
    end
end

function syrk!(uplo::UInt8, t::UInt8, n::Int, k::Int, alpha::T, A::ArrayArg{T}, lda::Int,
               beta::T, C::ArrayArg{T}, ldc::Int) where {T}
    # C := alpha A A' + beta C (t = 'N'), alpha A' A + beta C, in the `uplo` triangle
    for j in 1:n, i in (isupper(uplo) ? (1:j) : (j:n))
        s = zero(T)
        if alpha != 0
            for l in 1:k
                s += notrans(t) ? elem(A, lda, i, l) * elem(A, lda, j, l) :
                                  elem(A, lda, l, i) * elem(A, lda, l, j)
            end
        end
        update!(C, ldc, i, j, alpha, s, beta)
    end
end

function symm!(side::UInt8, uplo::UInt8, m::Int, n::Int, alpha::T, A::ArrayArg{T}, lda::Int,
               B::ArrayArg{T}, ldb::Int, beta::T, C::ArrayArg{T}, ldc::Int) where {T}
    # C := alpha A B + beta C (left) or alpha B A + beta C, A symmetric
    for j in 1:n, i in 1:m
        s = zero(T)
        if alpha != 0
            if isleft(side)
                for l in 1:m
                    s += symelem(A, lda, uplo, i, l) * elem(B, ldb, l, j)
                end
            else
                for l in 1:n
                    s += elem(B, ldb, i, l) * symelem(A, lda, uplo, l, j)
                end
            end
        end
        update!(C, ldc, i, j, alpha, s, beta)
    end
end

function trmm!(side::UInt8, uplo::UInt8, t::UInt8, diag::UInt8, m::Int, n::Int, alpha::T,
               A::ArrayArg{T}, lda::Int, B::ArrayArg{T}, ldb::Int) where {T}
    # B := alpha op(A) B (left) or alpha B op(A), in the order that reads each element of B
    # before it is overwritten
    alpha == 0 && return zero_matrix!(m, n, B, ldb)
    up = opupper(uplo, t)
    if isleft(side)
        for j in 1:n, i in (up ? (1:m) : (m:-1:1))
            s = zero(T)
            for l in (up ? (i:m) : (1:i))
                s += trielem(A, lda, uplo, t, diag, i, l) * elem(B, ldb, l, j)
            end
            setelem!(B, ldb, i, j, alpha * s)
        end
    else
        for i in 1:m, j in (up ? (n:-1:1) : (1:n))
            s = zero(T)
            for l in (up ? (1:j) : (j:n))
                s += elem(B, ldb, i, l) * trielem(A, lda, uplo, t, diag, l, j)
            end
            setelem!(B, ldb, i, j, alpha * s)
        end
    end
end

function trsm!(side::UInt8, uplo::UInt8, t::UInt8, diag::UInt8, m::Int, n::Int, alpha::T,
               A::ArrayArg{T}, lda::Int, B::ArrayArg{T}, ldb::Int) where {T}
    # op(A) X = alpha B (left) or X op(A) = alpha B, X overwriting B
    alpha == 0 && return zero_matrix!(m, n, B, ldb)
    up = opupper(uplo, t)
    if isleft(side)
        for j in 1:n, i in (up ? (m:-1:1) : (1:m))
            s = alpha * elem(B, ldb, i, j)
            for l in (up ? (i+1:m) : (1:i-1))
                s -= trielem(A, lda, uplo, t, diag, i, l) * elem(B, ldb, l, j)
            end
            setelem!(B, ldb, i, j, isunit(diag) ? s : s / trielem(A, lda, uplo, t, diag, i, i))
        end
    else
        for i in 1:m, j in (up ? (1:n) : (n:-1:1))
            s = alpha * elem(B, ldb, i, j)
            for l in (up ? (1:j-1) : (j+1:n))
                s -= elem(B, ldb, i, l) * trielem(A, lda, uplo, t, diag, l, j)
            end
            setelem!(B, ldb, i, j, isunit(diag) ? s : s / trielem(A, lda, uplo, t, diag, j, j))
        end
    end
end

end
