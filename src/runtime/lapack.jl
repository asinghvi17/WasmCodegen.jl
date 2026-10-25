# LAPACK, for what LinearAlgebra's factorizations call: LU (`getrf`, `getrs`, `getri`),
# Cholesky (`potrf`, `potrs`), Bunch-Kaufman (`sytrf`, `sytrs` and their rook variants), QR,
# SVD and symmetric eigenvalues, triangular solves (`trtrs`) and copies (`lacpy`), on real
# elements, with unblocked algorithms over the BLAS kernels (`blas.jl`). Outputs (`info`,
# pivots) are written through their arguments. Results can differ from an optimized
# LAPACK's in their last bits.

module LAPACK

using ..BLAS: ArrayArg, ld, st!, elem, setelem!, notrans, isupper, trsm!

setinfo!(info, v::Int) = st!(info, 1, v)

function swaprows!(A, lda::Int, p::Int, q::Int, n::Int)
    for j in 1:n
        a = elem(A, lda, p, j)
        setelem!(A, lda, p, j, elem(A, lda, q, j))
        setelem!(A, lda, q, j, a)
    end
end

"`getrf`: A = P L U with partial pivoting; `info` > 0 at the first zero pivot."
function getrf!(m::Int, n::Int, A::ArrayArg{T}, lda::Int, ipiv::ArrayArg{Int}, info) where {T}
    inf = 0
    for j in 1:min(m, n)
        # the pivot: the first element of largest absolute value in the column
        p, big = j, abs(elem(A, lda, j, j))
        for i in j+1:m
            a = abs(elem(A, lda, i, j))
            a > big && (p = i; big = a)
        end
        st!(ipiv, j, p)
        piv = elem(A, lda, p, j)
        if piv != 0
            p != j && swaprows!(A, lda, j, p, n)
            for i in j+1:m
                setelem!(A, lda, i, j, elem(A, lda, i, j) / piv)
            end
        elseif inf == 0
            inf = j
        end
        for jj in j+1:n
            a = elem(A, lda, j, jj)
            a == 0 && continue
            for i in j+1:m
                setelem!(A, lda, i, jj, elem(A, lda, i, jj) - elem(A, lda, i, j) * a)
            end
        end
    end
    setinfo!(info, inf)
end

"`getrs`: solve A X = B (or Aᵀ X = B) with the factors of `getrf`, X overwriting B."
function getrs!(trans::UInt8, n::Int, nrhs::Int, A::ArrayArg{T}, lda::Int, ipiv::ArrayArg{Int},
                B::ArrayArg{T}, ldb::Int, info) where {T}
    setinfo!(info, 0)
    (n == 0 || nrhs == 0) && return
    U8 = UInt8
    if notrans(trans)
        for i in 1:n
            p = ld(ipiv, i)
            p != i && swaprows!(B, ldb, i, p, nrhs)
        end
        trsm!(U8('L'), U8('L'), U8('N'), U8('U'), n, nrhs, one(T), A, lda, B, ldb)
        trsm!(U8('L'), U8('U'), U8('N'), U8('N'), n, nrhs, one(T), A, lda, B, ldb)
    else
        trsm!(U8('L'), U8('U'), U8('T'), U8('N'), n, nrhs, one(T), A, lda, B, ldb)
        trsm!(U8('L'), U8('L'), U8('T'), U8('U'), n, nrhs, one(T), A, lda, B, ldb)
        for i in n:-1:1
            p = ld(ipiv, i)
            p != i && swaprows!(B, ldb, i, p, nrhs)
        end
    end
end

"`getri`: the inverse from the factors of `getrf` (a workspace query where `lwork` is -1)."
function getri!(n::Int, A::ArrayArg{T}, lda::Int, ipiv::ArrayArg{Int}, work::ArrayArg{T},
                lwork::Int, info) where {T}
    if lwork == -1
        st!(work, 1, T(max(1, n)))
        setinfo!(info, 0)
        return
    end
    for i in 1:n
        if elem(A, lda, i, i) == 0
            setinfo!(info, i)
            return
        end
    end
    # solve A X = I into a copy, then copy back
    X = zeros(T, n * n)
    for i in 1:n
        X[i + (i - 1) * n] = one(T)
    end
    getrs!(UInt8('N'), n, n, A, lda, ipiv, X.ref, n, info)
    for j in 1:n, i in 1:n
        setelem!(A, lda, i, j, X[i + (j - 1) * n])
    end
    setinfo!(info, 0)
end

"`potrf`: the Cholesky factor (A = UᵀU or L Lᵀ) in the `uplo` triangle; `info` > 0 where A
is not positive definite."
function potrf!(uplo::UInt8, n::Int, A::ArrayArg{T}, lda::Int, info) where {T}
    up = isupper(uplo)
    # (the factor's element (k, j) of the stored triangle)
    f(k, j) = up ? elem(A, lda, k, j) : elem(A, lda, j, k)
    for j in 1:n
        s = elem(A, lda, j, j)
        for k in 1:j-1
            s -= f(k, j)^2
        end
        if !(s > 0)
            setelem!(A, lda, j, j, s)
            setinfo!(info, j)
            return
        end
        d = sqrt(s)
        setelem!(A, lda, j, j, d)
        for i in j+1:n
            t = up ? elem(A, lda, j, i) : elem(A, lda, i, j)
            for k in 1:j-1
                t -= f(k, j) * f(k, i)
            end
            up ? setelem!(A, lda, j, i, t / d) : setelem!(A, lda, i, j, t / d)
        end
    end
    setinfo!(info, 0)
end

"`potrs`: solve A X = B with the Cholesky factor of `potrf`."
function potrs!(uplo::UInt8, n::Int, nrhs::Int, A::ArrayArg{T}, lda::Int, B::ArrayArg{T},
                ldb::Int, info) where {T}
    setinfo!(info, 0)
    U8 = UInt8
    if isupper(uplo)
        trsm!(U8('L'), U8('U'), U8('T'), U8('N'), n, nrhs, one(T), A, lda, B, ldb)
        trsm!(U8('L'), U8('U'), U8('N'), U8('N'), n, nrhs, one(T), A, lda, B, ldb)
    else
        trsm!(U8('L'), U8('L'), U8('N'), U8('N'), n, nrhs, one(T), A, lda, B, ldb)
        trsm!(U8('L'), U8('L'), U8('T'), U8('N'), n, nrhs, one(T), A, lda, B, ldb)
    end
end

"`trtrs`: solve op(A) X = B for a triangular A; `info` > 0 at a zero on its diagonal."
function trtrs!(uplo::UInt8, trans::UInt8, diag::UInt8, n::Int, nrhs::Int, A::ArrayArg{T}, lda::Int,
                B::ArrayArg{T}, ldb::Int, info) where {T}
    if !(diag == UInt8('U') || diag == UInt8('u'))
        for i in 1:n
            if elem(A, lda, i, i) == 0
                setinfo!(info, i)
                return
            end
        end
    end
    trsm!(UInt8('L'), uplo, trans, diag, n, nrhs, one(T), A, lda, B, ldb)
    setinfo!(info, 0)
end

"`lacpy`: B := A, its `uplo` triangle or all of it."
function lacpy!(uplo::UInt8, m::Int, n::Int, A::ArrayArg{T}, lda::Int, B::ArrayArg{T}, ldb::Int) where {T}
    for j in 1:n
        rows = isupper(uplo) ? (1:min(j, m)) : (uplo == UInt8('L') || uplo == UInt8('l')) ? (j:m) : (1:m)
        for i in rows
            setelem!(B, ldb, i, j, elem(A, lda, i, j))
        end
    end
end

## QR

# a Householder reflector for the `n` values `alpha` and `x[k]` = A[i(k), j(k)] (k = 1:n-1):
# (beta, tau) with H [alpha; x] = [beta; 0], H = I - tau [1; v] [1; v]ᵀ, x overwritten by v
function larfg!(n::Int, alpha::T, A, lda::Int, i, j) where {T}
    n <= 1 && return alpha, zero(T)
    scale, ssq = zero(T), one(T)
    for k in 1:n-1
        x = elem(A, lda, i(k), j(k))
        if x != 0
            a = abs(x)
            scale < a ? (ssq = one(T) + ssq * (scale / a)^2; scale = a) : (ssq += (a / scale)^2)
        end
    end
    xnorm = scale * sqrt(ssq)
    xnorm == 0 && return alpha, zero(T)
    beta = -copysign(hypot(alpha, xnorm), alpha)
    tau = (beta - alpha) / beta
    f = one(T) / (alpha - beta)
    for k in 1:n-1
        setelem!(A, lda, i(k), j(k), f * elem(A, lda, i(k), j(k)))
    end
    return beta, tau
end

# C[r0:r1, c0:c1] := (I - tau v vᵀ) C[...] where v = [1; V[i+1:i+len-1, j]] (rows of C from
# r0), the reflector of column `j` of the factor `V` from row `i`
function reflect_left!(C, ldc::Int, r0::Int, r1::Int, c0::Int, c1::Int, tau::T, V, ldv::Int, i::Int, j::Int) where {T}
    tau == 0 && return
    for c in c0:c1
        w = elem(C, ldc, r0, c)
        for q in 1:r1-r0
            w += elem(V, ldv, i + q, j) * elem(C, ldc, r0 + q, c)
        end
        w *= tau
        setelem!(C, ldc, r0, c, elem(C, ldc, r0, c) - w)
        for q in 1:r1-r0
            setelem!(C, ldc, r0 + q, c, elem(C, ldc, r0 + q, c) - w * elem(V, ldv, i + q, j))
        end
    end
end

# C[r0:r1, c0:c1] := C[...] (I - tau v vᵀ), v = [1; V[i+1:i+len-1, j]] over the columns from c0
function reflect_right!(C, ldc::Int, r0::Int, r1::Int, c0::Int, c1::Int, tau::T, V, ldv::Int, i::Int, j::Int) where {T}
    tau == 0 && return
    for r in r0:r1
        w = elem(C, ldc, r, c0)
        for q in 1:c1-c0
            w += elem(C, ldc, r, c0 + q) * elem(V, ldv, i + q, j)
        end
        w *= tau
        setelem!(C, ldc, r, c0, elem(C, ldc, r, c0) - w)
        for q in 1:c1-c0
            setelem!(C, ldc, r, c0 + q, elem(C, ldc, r, c0 + q) - w * elem(V, ldv, i + q, j))
        end
    end
end

function swapcols!(A, lda::Int, p::Int, q::Int, m::Int)
    for i in 1:m
        a = elem(A, lda, i, p)
        setelem!(A, lda, i, p, elem(A, lda, i, q))
        setelem!(A, lda, i, q, a)
    end
end

colnorm(A::ArrayArg{T}, lda::Int, i0::Int, m::Int, j::Int) where {T} =
    sqrt(sum(k -> abs2(elem(A, lda, k, j)), i0:m; init=zero(T)))

"`geqp3`: A P = Q R with column pivoting (`dlaqp2`'s), the columns marked in `jpvt` first."
function geqp3!(m::Int, n::Int, A::ArrayArg{T}, lda::Int, jpvt::ArrayArg{Int}, tau::ArrayArg{T},
                work::ArrayArg{T}, lwork::Int, info) where {T}
    setinfo!(info, 0)
    if lwork == -1
        st!(work, 1, T(3n + 1))
        return
    end
    # the columns marked first, in order
    nfxd = 0
    for j in 1:n
        if ld(jpvt, j) != 0
            nfxd += 1
            if j != nfxd
                swapcols!(A, lda, j, nfxd, m)
                st!(jpvt, j, ld(jpvt, nfxd))
                st!(jpvt, nfxd, j)
            else
                st!(jpvt, j, j)
            end
        else
            st!(jpvt, j, j)
        end
    end
    vn1 = zeros(T, n)
    vn2 = zeros(T, n)
    for j in nfxd+1:n
        vn1[j] = vn2[j] = colnorm(A, lda, 1, m, j)
    end
    tol3z = sqrt(eps(T))
    for i in 1:min(m, n)
        if i > nfxd
            # the free column of largest remaining norm
            pvt, big = i, vn1[i]
            for j in i+1:n
                vn1[j] > big && (pvt = j; big = vn1[j])
            end
            if pvt != i
                swapcols!(A, lda, pvt, i, m)
                p = ld(jpvt, pvt); st!(jpvt, pvt, ld(jpvt, i)); st!(jpvt, i, p)
                vn1[pvt] = vn1[i]; vn2[pvt] = vn2[i]
            end
        end
        beta, t = larfg!(m - i + 1, elem(A, lda, i, i), A, lda, k -> i + k, k -> i)
        setelem!(A, lda, i, i, beta)
        st!(tau, i, t)
        i < n && reflect_left!(A, lda, i, m, i + 1, n, t, A, lda, i, i)
        # the norms of the rest of the free columns, recomputed where cancellation lost them
        for j in max(i, nfxd)+1:n
            vn1[j] == 0 && continue
            temp = max(one(T) - (abs(elem(A, lda, i, j)) / vn1[j])^2, zero(T))
            if temp * (vn1[j] / vn2[j])^2 <= tol3z
                vn1[j] = vn2[j] = i < m ? colnorm(A, lda, i + 1, m, j) : zero(T)
            else
                vn1[j] *= sqrt(temp)
            end
        end
    end
end

# the order of applying k reflectors H(1)...H(k): forward for Qᵀ C and C Q
reflector_order(left::Bool, notran::Bool, k::Int) = (left != notran) ? (1:k) : (k:-1:1)

"`ormqr`: C := Q C, Qᵀ C, C Q or C Qᵀ, Q from the reflectors of `geqrf`/`geqp3` in A."
function ormqr!(side::UInt8, trans::UInt8, m::Int, n::Int, k::Int, A::ArrayArg{T}, lda::Int,
                tau::ArrayArg{T}, C::ArrayArg{T}, ldc::Int, work::ArrayArg{T}, lwork::Int, info) where {T}
    setinfo!(info, 0)
    left = side == UInt8('L') || side == UInt8('l')
    if lwork == -1
        st!(work, 1, T(max(1, left ? n : m)))
        return
    end
    for i in reflector_order(left, notrans(trans), k)
        t = ld(tau, i)
        left ? reflect_left!(C, ldc, i, m, 1, n, t, A, lda, i, i) :
               reflect_right!(C, ldc, 1, m, i, n, t, A, lda, i, i)
    end
end

"`tzrzf`: the upper trapezoidal m×n A (m ≤ n) to [R 0] Z, Z's reflectors in A's last n-m columns."
function tzrzf!(m::Int, n::Int, A::ArrayArg{T}, lda::Int, tau::ArrayArg{T}, work::ArrayArg{T},
                lwork::Int, info) where {T}
    setinfo!(info, 0)
    if lwork == -1
        st!(work, 1, T(max(1, m)))
        return
    end
    if m == n
        for i in 1:n
            st!(tau, i, zero(T))
        end
        return
    end
    l = n - m
    for i in m:-1:1
        # annihilate A[i, n-l+1:n] against A[i, i]
        beta, t = larfg!(l + 1, elem(A, lda, i, i), A, lda, k -> i, k -> n - l + k)
        setelem!(A, lda, i, i, beta)
        st!(tau, i, t)
        # A[1:i-1, i:n] := A[...] H(i) (H(i) acts on column i and the last l)
        t == 0 && continue
        for r in 1:i-1
            w = elem(A, lda, r, i)
            for q in 1:l
                w += elem(A, lda, r, n - l + q) * elem(A, lda, i, n - l + q)
            end
            w *= t
            setelem!(A, lda, r, i, elem(A, lda, r, i) - w)
            for q in 1:l
                setelem!(A, lda, r, n - l + q, elem(A, lda, r, n - l + q) - w * elem(A, lda, i, n - l + q))
            end
        end
    end
end

"`ormrz`: C := Z C, Zᵀ C, C Z or C Zᵀ, Z from the reflectors of `tzrzf` (`l` columns each)."
function ormrz!(side::UInt8, trans::UInt8, m::Int, n::Int, k::Int, l::Int, A::ArrayArg{T}, lda::Int,
                tau::ArrayArg{T}, C::ArrayArg{T}, ldc::Int, work::ArrayArg{T}, lwork::Int, info) where {T}
    setinfo!(info, 0)
    left = side == UInt8('L') || side == UInt8('l')
    if lwork == -1
        st!(work, 1, T(max(1, left ? n : m)))
        return
    end
    nq = left ? m : n
    ja = nq - l + 1
    for i in reflector_order(left, notrans(trans), k)
        t = ld(tau, i)
        t == 0 && continue
        v(q) = elem(A, lda, i, ja + q - 1)
        if left
            # rows i and m-l+1:m of C
            for c in 1:n
                w = elem(C, ldc, i, c)
                for q in 1:l
                    w += v(q) * elem(C, ldc, m - l + q, c)
                end
                w *= t
                setelem!(C, ldc, i, c, elem(C, ldc, i, c) - w)
                for q in 1:l
                    setelem!(C, ldc, m - l + q, c, elem(C, ldc, m - l + q, c) - w * v(q))
                end
            end
        else
            # columns i and n-l+1:n of C
            for r in 1:m
                w = elem(C, ldc, r, i)
                for q in 1:l
                    w += elem(C, ldc, r, n - l + q) * v(q)
                end
                w *= t
                setelem!(C, ldc, r, i, elem(C, ldc, r, i) - w)
                for q in 1:l
                    setelem!(C, ldc, r, n - l + q, elem(C, ldc, r, n - l + q) - w * v(q))
                end
            end
        end
    end
end

"`laic1`: one step of incremental condition estimation (LAPACK's `dlaic1`, case for case):
the largest (job 1) or smallest (job 2) singular value of [L 0; wᵀ gamma] from `sest` of L."
function laic1!(job::Int, j::Int, X::ArrayArg{T}, sest::T, W::ArrayArg{T}, gamma::T,
                sestpr_out, s_out, c_out) where {T}
    epsl = eps(T) / 2
    alpha = zero(T)
    for k in 1:j
        alpha += ld(X, k) * ld(W, k)
    end
    absalp, absgam, absest = abs(alpha), abs(gamma), abs(sest)
    one_, half, two, four = one(T), T(0.5), T(2), T(4)
    s = c = sestpr = zero(T)
    if job == 1
        if sest == 0
            s1 = max(absgam, absalp)
            if s1 == 0
                s, c, sestpr = zero(T), one_, zero(T)
            else
                s, c = alpha / s1, gamma / s1
                tmp = sqrt(s * s + c * c)
                s, c, sestpr = s / tmp, c / tmp, s1 * tmp
            end
        elseif absgam <= epsl * absest
            s, c = one_, zero(T)
            tmp = max(absest, absalp)
            s1, s2 = absest / tmp, absalp / tmp
            sestpr = tmp * sqrt(s1 * s1 + s2 * s2)
        elseif absalp <= epsl * absest
            s1, s2 = absgam, absest
            s1 <= s2 ? ((s, c, sestpr) = (one_, zero(T), s2)) : ((s, c, sestpr) = (zero(T), one_, s1))
        elseif absest <= epsl * absalp || absest <= epsl * absgam
            s1, s2 = absgam, absalp
            if s1 <= s2
                tmp = s1 / s2
                s = sqrt(one_ + tmp * tmp)
                sestpr = s2 * s
                c = (gamma / s2) / s
                s = copysign(one_, alpha) / s
            else
                tmp = s2 / s1
                c = sqrt(one_ + tmp * tmp)
                sestpr = s1 * c
                s = (alpha / s1) / c
                c = copysign(one_, gamma) / c
            end
        else
            zeta1, zeta2 = alpha / absest, gamma / absest
            b = (one_ - zeta1 * zeta1 - zeta2 * zeta2) * half
            c = zeta1 * zeta1
            t = b > 0 ? c / (b + sqrt(b * b + c)) : sqrt(b * b + c) - b
            sine, cosine = -zeta1 / t, -zeta2 / (one_ + t)
            tmp = sqrt(sine * sine + cosine * cosine)
            s, c = sine / tmp, cosine / tmp
            sestpr = sqrt(t + one_) * absest
        end
    else
        if sest == 0
            sestpr = zero(T)
            sine, cosine = max(absgam, absalp) == 0 ? (one_, zero(T)) : (-gamma, alpha)
            s1 = max(abs(sine), abs(cosine))
            s, c = sine / s1, cosine / s1
            tmp = sqrt(s * s + c * c)
            s, c = s / tmp, c / tmp
        elseif absgam <= epsl * absest
            s, c, sestpr = zero(T), one_, absgam
        elseif absalp <= epsl * absest
            s1, s2 = absgam, absest
            s1 <= s2 ? ((s, c, sestpr) = (zero(T), one_, s1)) : ((s, c, sestpr) = (one_, zero(T), s2))
        elseif absest <= epsl * absalp || absest <= epsl * absgam
            s1, s2 = absgam, absalp
            if s1 <= s2
                tmp = s1 / s2
                c = sqrt(one_ + tmp * tmp)
                sestpr = absest * (tmp / c)
                s = -(gamma / s2) / c
                c = copysign(one_, alpha) / c
            else
                tmp = s2 / s1
                s = sqrt(one_ + tmp * tmp)
                sestpr = absest / s
                c = (alpha / s1) / s
                s = -copysign(one_, gamma) / s
            end
        else
            zeta1, zeta2 = alpha / absest, gamma / absest
            norma = max(one_ + zeta1 * zeta1 + abs(zeta1 * zeta2), abs(zeta1 * zeta2) + zeta2 * zeta2)
            test = one_ + two * (zeta1 - zeta2) * (zeta1 + zeta2)
            if test >= 0
                b = (zeta1 * zeta1 + zeta2 * zeta2 + one_) * half
                c = zeta2 * zeta2
                t = c / (b + sqrt(abs(b * b - c)))
                sine, cosine = zeta1 / (one_ - t), -zeta2 / t
                sestpr = sqrt(t + four * epsl * epsl * norma) * absest
            else
                b = (zeta2 * zeta2 + zeta1 * zeta1 - one_) * half
                c = zeta1 * zeta1
                t = b >= 0 ? -c / (b + sqrt(b * b + c)) : b - sqrt(b * b + c)
                sine, cosine = -zeta1 / t, -zeta2 / (one_ + t)
                sestpr = sqrt(one_ + t + four * epsl * epsl * norma) * absest
            end
            tmp = sqrt(sine * sine + cosine * cosine)
            s, c = sine / tmp, cosine / tmp
        end
    end
    st!(sestpr_out, 1, sestpr)
    st!(s_out, 1, s)
    st!(c_out, 1, c)
end

"`geqrt`: A = Q R with Q in blocks of `nb` reflectors, each with its compact WY factor T
(Q's block = I - V T Vᵀ), T's blocks side by side in its first `nb` rows."
function geqrt!(m::Int, n::Int, nb::Int, A::ArrayArg{T}, lda::Int, Tm::ArrayArg{T}, ldt::Int,
                work::ArrayArg{T}, info) where {T}
    setinfo!(info, 0)
    k = min(m, n)
    for i in 1:nb:k
        ib = min(k - i + 1, nb)
        for j in i:i+ib-1
            beta, t = larfg!(m - j + 1, elem(A, lda, j, j), A, lda, q -> j + q, q -> j)
            setelem!(A, lda, j, j, beta)
            j < n && reflect_left!(A, lda, j, m, j + 1, n, t, A, lda, j, j)
            # T[1:jj, j] of the block (dlarft, forward, columnwise): its diagonal is tau, above it
            # -tau T[1:jj-1, 1:jj-1] V[:, 1:jj-1]ᵀ v
            jj = j - i + 1
            setelem!(Tm, ldt, jj, j, t)
            for r in 1:jj-1
                # V[:, r]ᵀ v (both unit at their own first row, zero above)
                dotv = elem(A, lda, j, i + r - 1)
                for q in j+1:m
                    dotv += elem(A, lda, q, i + r - 1) * elem(A, lda, q, j)
                end
                setelem!(Tm, ldt, r, j, -t * dotv)
            end
            for r in 1:jj-1
                acc = zero(T)
                for q in r:jj-1
                    acc += elem(Tm, ldt, r, i + q - 1) * elem(Tm, ldt, q, j)
                end
                setelem!(Tm, ldt, r, j, acc)
            end
        end
    end
end

"`gemqrt`: C := Q C, Qᵀ C, C Q or C Qᵀ, with Q's blocks from `geqrt` (V and T)."
function gemqrt!(side::UInt8, trans::UInt8, m::Int, n::Int, k::Int, nb::Int, V::ArrayArg{T}, ldv::Int,
                 Tm::ArrayArg{T}, ldt::Int, C::ArrayArg{T}, ldc::Int, work::ArrayArg{T}, info) where {T}
    setinfo!(info, 0)
    left = side == UInt8('L') || side == UInt8('l')
    notran = notrans(trans)
    blocks = collect(1:nb:k)
    # (Qᵀ C and C Q apply the blocks first to last)
    (left != notran) || reverse!(blocks)
    for i in blocks
        ib = min(k - i + 1, nb)
        # the block's V: rows i:nq, unit lower trapezoidal
        vv(q, r) = q < i + r - 1 ? zero(T) : q == i + r - 1 ? one(T) : elem(V, ldv, q, i + r - 1)
        tt(a, b) = elem(Tm, ldt, a, i + b - 1)
        if left
            # C[i:m, :] := (I - V T' Vᵀ) C, T' = T or Tᵀ: W = Vᵀ C, W = T'ᵀ... applied column by column
            for c in 1:n
                w = [sum(q -> vv(q, r) * elem(C, ldc, q, c), i:m; init=zero(T)) for r in 1:ib]
                # Qᵀ: H = I - V Tᵀ Vᵀ; Q: I - V T Vᵀ
                w2 = [notran ? sum(b -> tt(a, b) * w[b], a:ib; init=zero(T)) :
                               sum(b -> tt(b, a) * w[b], 1:a; init=zero(T)) for a in 1:ib]
                for q in i:m
                    setelem!(C, ldc, q, c, elem(C, ldc, q, c) - sum(r -> vv(q, r) * w2[r], 1:ib; init=zero(T)))
                end
            end
        else
            # C[:, i:n] := C (I - V T' Vᵀ): W = C V, W = W T', C -= W Vᵀ, row by row
            for r0 in 1:m
                w = [sum(q -> elem(C, ldc, r0, q) * vv(q, r), i:n; init=zero(T)) for r in 1:ib]
                w2 = [notran ? sum(a -> w[a] * tt(a, b), 1:b; init=zero(T)) :
                               sum(a -> w[a] * tt(b, a), b:ib; init=zero(T)) for b in 1:ib]
                for q in i:n
                    setelem!(C, ldc, r0, q, elem(C, ldc, r0, q) - sum(r -> w2[r] * vv(q, r), 1:ib; init=zero(T)))
                end
            end
        end
    end
end

## symmetric eigenvalues and singular values (Jacobi's methods)

# the power of 2 to scale the matrix X by so that its largest magnitude is 1, where it is out
# of the range in which sums of squares of its elements neither overflow nor underflow (else
# 0), as LAPACK scales: the rotations are computed of X·2^e, the values unscaled after
function jacobi_scale!(X::Matrix{T}) where {T}
    amax = maximum(abs, X; init=zero(T))
    rmin = sqrt(floatmin(T) / eps(T))
    (iszero(amax) || !isfinite(amax) || rmin <= amax <= inv(rmin)) && return 0
    e = -exponent(amax)
    X .= ldexp.(X, e)
    return e
end

# the eigenvalues (ascending) and eigenvectors (columns of V, n×n) of the symmetric n×n S,
# by cyclic Jacobi rotations, until the off-diagonal elements are negligible
function jacobi_eigen!(S::Matrix{T}, n::Int) where {T}
    V = zeros(T, n, n)
    for i in 1:n
        V[i, i] = one(T)
    end
    e = jacobi_scale!(S)
    for sweep in 1:100
        off = dia = zero(T)
        for q in 1:n
            dia += S[q, q]^2
            for p in 1:q-1
                off += S[p, q]^2
            end
        end
        off <= (eps(T) / 2)^2 * (dia + off) && break
        for q in 2:n, p in 1:q-1
            apq = S[p, q]
            apq == 0 && continue
            theta = (S[q, q] - S[p, p]) / (2apq)
            t = copysign(one(T), theta) / (abs(theta) + sqrt(theta^2 + one(T)))
            isfinite(theta) || (t = apq / (S[q, q] - S[p, p]))
            c = one(T) / sqrt(t^2 + one(T))
            s = t * c
            for k in 1:n
                skp, skq = S[k, p], S[k, q]
                S[k, p] = c * skp - s * skq
                S[k, q] = s * skp + c * skq
            end
            for k in 1:n
                spk, sqk = S[p, k], S[q, k]
                S[p, k] = c * spk - s * sqk
                S[q, k] = s * spk + c * sqk
            end
            for k in 1:n
                vkp, vkq = V[k, p], V[k, q]
                V[k, p] = c * vkp - s * vkq
                V[k, q] = s * vkp + c * vkq
            end
        end
    end
    w = T[ldexp(S[i, i], -e) for i in 1:n]
    perm = sortperm(w)
    return w[perm], V[:, perm]
end

"""`syevr`: the eigenvalues (ascending) and, with `jobz` 'V', eigenvectors of the symmetric
A (stored in its `uplo` triangle): all of them (`range` 'A'), those in (vl, vu] ('V'), or
the il-th to iu-th ('I'). A's triangle is destroyed. A workspace query where `lwork` or
`liwork` is -1."""
function syevr!(jobz::UInt8, range::UInt8, uplo::UInt8, n::Int, A::ArrayArg{T}, lda::Int,
                vl::T, vu::T, il::Int, iu::Int, abstol::T, m::ArrayArg{Int}, W::ArrayArg{T},
                Z::ArrayArg{T}, ldz::Int, isuppz::ArrayArg{Int}, work::ArrayArg{T}, lwork::Int,
                iwork::ArrayArg{Int}, liwork::Int, info) where {T}
    setinfo!(info, 0)
    if lwork == -1 || liwork == -1
        st!(work, 1, T(max(1, 26n)))
        st!(iwork, 1, max(1, 10n))
        return
    end
    S = Matrix{T}(undef, n, n)
    up = isupper(uplo)
    for j in 1:n, i in 1:n
        S[i, j] = (up ? i <= j : i >= j) ? elem(A, lda, i, j) : elem(A, lda, j, i)
    end
    w, V = jacobi_eigen!(S, n)
    sel = range == UInt8('V') || range == UInt8('v') ? [k for k in 1:n if vl < w[k] <= vu] :
          range == UInt8('I') || range == UInt8('i') ? collect(il:iu) : collect(1:n)
    st!(m, 1, length(sel))
    for (k, j) in enumerate(sel)
        st!(W, k, w[j])
        if jobz == UInt8('V') || jobz == UInt8('v')
            for i in 1:n
                setelem!(Z, ldz, i, k, V[i, j])
            end
        end
    end
end

"""
    jacobi_svd(m, n, A, lda, fullu, fullv) -> (S, U, V)

The singular values (descending) of the m×n A, and its left and right singular vectors: the
first min(m, n) of each, or all (`fullu`, `fullv`, completed to orthonormal bases), by
one-sided Jacobi rotations.
"""
function jacobi_svd(m::Int, n::Int, A::ArrayArg{T}, lda::Int, fullu::Bool, fullv::Bool) where {T}
    k = min(m, n)
    # (on Aᵀ if wider than tall: its columns are the rows)
    tall = m >= n
    p, q = tall ? (m, n) : (n, m)
    G = Matrix{T}(undef, p, q)
    for j in 1:q, i in 1:p
        G[i, j] = tall ? elem(A, lda, i, j) : elem(A, lda, j, i)
    end
    V = zeros(T, q, q)
    for i in 1:q
        V[i, i] = one(T)
    end
    e = jacobi_scale!(G)
    tol = eps(T) * p
    for sweep in 1:100
        rotated = false
        for b in 2:q, a in 1:b-1
            alpha = beta = gamma = zero(T)
            for i in 1:p
                alpha += G[i, a]^2; beta += G[i, b]^2; gamma += G[i, a] * G[i, b]
            end
            # (the norms' product, and zeta's, without overflow: G is scaled only to below
            # sqrt(floatmax), its squares' sums to below floatmax)
            (gamma == 0 || abs(gamma) <= tol * (sqrt(alpha) * sqrt(beta))) && continue
            rotated = true
            zeta = (beta - alpha) / (2gamma)
            t = copysign(one(T), zeta) / (abs(zeta) + hypot(one(T), zeta))
            c = one(T) / sqrt(one(T) + t^2)
            s = c * t
            for i in 1:p
                ga, gb = G[i, a], G[i, b]
                G[i, a] = c * ga - s * gb
                G[i, b] = s * ga + c * gb
            end
            for i in 1:q
                va, vb = V[i, a], V[i, b]
                V[i, a] = c * va - s * vb
                V[i, b] = s * va + c * vb
            end
        end
        rotated || break
    end
    sv = T[sqrt(sum(abs2, view(G, :, j))) for j in 1:q]
    perm = sortperm(sv; rev=true)
    S = T[ldexp(sv[perm[j]], -e) for j in 1:k]
    # the left vectors of G (normalized columns, completed to an orthonormal basis), the right
    # ones V; for Aᵀ they swap
    fulll, fullr = tall ? (fullu, fullv) : (fullv, fullu)
    L = zeros(T, p, fulll ? p : k)
    for j in 1:k
        c = perm[j]
        sv[c] > 0 && (L[:, j] .= view(G, :, c) ./ sv[c])
    end
    ncols = size(L, 2)
    next = 1
    for j in 1:ncols
        sv_j = j <= k ? sv[perm[j]] : zero(T)
        (j <= k && sv_j > 0) && continue
        # a unit vector orthogonal to the previous columns (Gram-Schmidt on e_next)
        while next <= p
            v = zeros(T, p); v[next] = one(T); next += 1
            for r in 1:ncols
                r == j && continue
                d = sum(i -> L[i, r] * v[i], 1:p)
                v .-= d .* view(L, :, r)
            end
            nv = sqrt(sum(abs2, v))
            if nv > T(0.1)
                L[:, j] .= v ./ nv
                break
            end
        end
    end
    R = zeros(T, q, fullr ? q : k)
    for j in 1:size(R, 2)
        R[:, j] .= view(V, :, perm[j])
    end
    return tall ? (S, L, R) : (S, R, L)
end

# the m×c matrix U into the array X (leading dimension ldx), and Vᵀ of the n×r V
function put_u!(X::ArrayArg{T}, ldx::Int, U::Matrix{T}) where {T}
    for j in 1:size(U, 2), i in 1:size(U, 1)
        setelem!(X, ldx, i, j, U[i, j])
    end
end
function put_vt!(X::ArrayArg{T}, ldx::Int, V::Matrix{T}) where {T}
    for j in 1:size(V, 1), i in 1:size(V, 2)
        setelem!(X, ldx, i, j, V[j, i])
    end
end

"""`gesdd`: the singular values (descending) of the m×n A and, by `jobz`, none of the
singular vectors ('N'), the first min(m, n) of each ('S', U m×k, Vᵀ k×n) or all ('A', U
m×m, Vᵀ n×n). A is destroyed. A workspace query where `lwork` is -1."""
function gesdd!(jobz::UInt8, m::Int, n::Int, A::ArrayArg{T}, lda::Int, S::ArrayArg{T},
                U::ArrayArg{T}, ldu::Int, VT::ArrayArg{T}, ldvt::Int, work::ArrayArg{T},
                lwork::Int, iwork::ArrayArg{Int}, info) where {T}
    setinfo!(info, 0)
    if lwork == -1
        st!(work, 1, T(max(1, 4 * (m + n)^2)))
        return
    end
    full = jobz == UInt8('A') || jobz == UInt8('a')
    sv, Uc, Vc = jacobi_svd(m, n, A, lda, full, full)
    for j in eachindex(sv)
        st!(S, j, sv[j])
    end
    (jobz == UInt8('N') || jobz == UInt8('n')) && return
    put_u!(U, ldu, Uc)
    put_vt!(VT, ldvt, Vc)
end

"""`gesvd`: as `gesdd`, the left and right singular vectors chosen separately (`jobu`,
`jobvt`): none ('N'), the first min(m, n) ('S', or 'O': written over A) or all ('A')."""
function gesvd!(jobu::UInt8, jobvt::UInt8, m::Int, n::Int, A::ArrayArg{T}, lda::Int,
                S::ArrayArg{T}, U::ArrayArg{T}, ldu::Int, VT::ArrayArg{T}, ldvt::Int,
                work::ArrayArg{T}, lwork::Int, info) where {T}
    setinfo!(info, 0)
    if lwork == -1
        st!(work, 1, T(max(1, 4 * (m + n)^2)))
        return
    end
    job(c) = c | 0x20  # (lowercase)
    sv, Uc, Vc = jacobi_svd(m, n, A, lda, job(jobu) == UInt8('a'), job(jobvt) == UInt8('a'))
    for j in eachindex(sv)
        st!(S, j, sv[j])
    end
    job(jobu) in (UInt8('a'), UInt8('s')) && put_u!(U, ldu, Uc)
    job(jobvt) in (UInt8('a'), UInt8('s')) && put_vt!(VT, ldvt, Vc)
    job(jobu) == UInt8('o') && put_u!(A, lda, Uc)
    job(jobvt) == UInt8('o') && put_vt!(A, lda, Vc)
end


## symmetric indefinite: A = U D Uᵀ or L D Lᵀ, D of 1×1 and 2×2 blocks (Bunch-Kaufman, LAPACK's
## unblocked `dsytf2` and `dsytf2_rook`, and their solves)

# the first of the n elements of largest magnitude from A(i, j) in steps (di, dj) (`idamax`)
function iamax_at(A::ArrayArg{T}, lda::Int, n::Int, i::Int, j::Int, di::Int, dj::Int) where {T}
    n < 1 && return 0
    k, m = 1, abs(elem(A, lda, i, j))
    for t in 2:n
        a = abs(elem(A, lda, i + (t - 1) * di, j + (t - 1) * dj))
        a > m && ((k, m) = (t, a))
    end
    return k
end

# swap the n elements from A(i1, j1) in steps (a1, b1) with those from A(i2, j2) (`dswap`)
function swap_at!(A, lda::Int, n::Int, i1::Int, j1::Int, a1::Int, b1::Int, i2::Int, j2::Int, a2::Int, b2::Int)
    for t in 0:n-1
        x = elem(A, lda, i1 + t * a1, j1 + t * b1)
        setelem!(A, lda, i1 + t * a1, j1 + t * b1, elem(A, lda, i2 + t * a2, j2 + t * b2))
        setelem!(A, lda, i2 + t * a2, j2 + t * b2, x)
    end
end
swap_diag!(A, lda::Int, p::Int, q::Int) =
    (x = elem(A, lda, p, p); setelem!(A, lda, p, p, elem(A, lda, q, q)); setelem!(A, lda, q, q, x))

# the symmetric rank-1 update of the n×n block from A(o+1, o+1), in its `upper` triangle or
# the lower one, with the n elements of the column `c` of A from row `r` (`dsyr`)
function syr_at!(A::ArrayArg{T}, lda::Int, upper::Bool, n::Int, alpha::T, r::Int, c::Int, o::Int) where {T}
    for j in 1:n
        xj = elem(A, lda, r + j - 1, c)
        xj == 0 && continue
        t = alpha * xj
        for i in (upper ? (1:j) : (j:n))
            setelem!(A, lda, o + i, o + j, elem(A, lda, o + i, o + j) + elem(A, lda, r + i - 1, c) * t)
        end
    end
end

"""`sytf2`/`sytf2_rook`: the factorization of `sytrf` (Bunch-Kaufman's partial pivoting) or
`sytrf_rook` (rook pivoting), unblocked; `info` > 0 at the first zero pivot."""
function sytf2!(uplo::UInt8, n::Int, A::ArrayArg{T}, lda::Int, ipiv::ArrayArg{Int}, info, rook::Bool) where {T}
    alpha = (one(T) + sqrt(T(17))) / 8
    sfmin = floatmin(T)
    inf = 0
    upper = isupper(uplo)
    k = upper ? n : 1
    while upper ? k >= 1 : k <= n
        kstep = 1
        p = k
        absakk = abs(elem(A, lda, k, k))
        if upper
            imax = k > 1 ? iamax_at(A, lda, k - 1, 1, k, 1, 0) : 0
        else
            imax = k < n ? k + iamax_at(A, lda, n - k, k + 1, k, 1, 0) : 0
        end
        colmax = imax > 0 ? abs(elem(A, lda, imax, k)) : zero(T)
        if max(absakk, colmax) == 0 || (!rook && isnan(absakk))
            inf == 0 && (inf = k)
            kp = k
        else
            if !(absakk < alpha * colmax)
                kp = k
            elseif !rook
                # the largest off-diagonal element of the row and column imax
                if upper
                    jmax = imax + iamax_at(A, lda, k - imax, imax, imax + 1, 0, 1)
                    rowmax = abs(elem(A, lda, imax, jmax))
                    if imax > 1
                        jmax = iamax_at(A, lda, imax - 1, 1, imax, 1, 0)
                        rowmax = max(rowmax, abs(elem(A, lda, jmax, imax)))
                    end
                else
                    jmax = k - 1 + iamax_at(A, lda, imax - k, imax, k, 0, 1)
                    rowmax = abs(elem(A, lda, imax, jmax))
                    if imax < n
                        jmax = imax + iamax_at(A, lda, n - imax, imax + 1, imax, 1, 0)
                        rowmax = max(rowmax, abs(elem(A, lda, jmax, imax)))
                    end
                end
                if absakk >= alpha * colmax * (colmax / rowmax)
                    kp = k
                elseif abs(elem(A, lda, imax, imax)) >= alpha * rowmax
                    kp = imax
                else
                    kp = imax
                    kstep = 2
                end
            else
                # rook: along rows and columns until a pivot (or a 2×2 one) is found
                while true
                    if upper
                        if imax != k
                            jmax = imax + iamax_at(A, lda, k - imax, imax, imax + 1, 0, 1)
                            rowmax = abs(elem(A, lda, imax, jmax))
                        else
                            rowmax = zero(T)
                        end
                        if imax > 1
                            itemp = iamax_at(A, lda, imax - 1, 1, imax, 1, 0)
                            dtemp = abs(elem(A, lda, itemp, imax))
                            dtemp > rowmax && ((rowmax, jmax) = (dtemp, itemp))
                        end
                    else
                        if imax != k
                            jmax = k - 1 + iamax_at(A, lda, imax - k, imax, k, 0, 1)
                            rowmax = abs(elem(A, lda, imax, jmax))
                        else
                            rowmax = zero(T)
                        end
                        if imax < n
                            itemp = imax + iamax_at(A, lda, n - imax, imax + 1, imax, 1, 0)
                            dtemp = abs(elem(A, lda, itemp, imax))
                            dtemp > rowmax && ((rowmax, jmax) = (dtemp, itemp))
                        end
                    end
                    if !(abs(elem(A, lda, imax, imax)) < alpha * rowmax)
                        kp = imax
                        break
                    elseif p == jmax || rowmax <= colmax
                        kp = imax
                        kstep = 2
                        break
                    else
                        p = imax
                        colmax = rowmax
                        imax = jmax
                    end
                end
            end
            kk = upper ? k - kstep + 1 : k + kstep - 1
            if rook && kstep == 2 && p != k
                if upper
                    p > 1 && swap_at!(A, lda, p - 1, 1, k, 1, 0, 1, p, 1, 0)
                    p < k - 1 && swap_at!(A, lda, k - p - 1, p + 1, k, 1, 0, p, p + 1, 0, 1)
                else
                    p < n && swap_at!(A, lda, n - p, p + 1, k, 1, 0, p + 1, p, 1, 0)
                    p > k + 1 && swap_at!(A, lda, p - k - 1, k + 1, k, 1, 0, p, k + 1, 0, 1)
                end
                swap_diag!(A, lda, k, p)
            end
            if kp != kk
                # interchange rows and columns kk and kp of the trailing (or leading) block
                if upper
                    kp > 1 && swap_at!(A, lda, kp - 1, 1, kk, 1, 0, 1, kp, 1, 0)
                    kk - kp - 1 > 0 && swap_at!(A, lda, kk - kp - 1, kp + 1, kk, 1, 0, kp, kp + 1, 0, 1)
                else
                    kp < n && swap_at!(A, lda, n - kp, kp + 1, kk, 1, 0, kp + 1, kp, 1, 0)
                    kp - kk - 1 > 0 && swap_at!(A, lda, kp - kk - 1, kk + 1, kk, 1, 0, kp, kk + 1, 0, 1)
                end
                swap_diag!(A, lda, kk, kp)
                if kstep == 2
                    r = upper ? k - 1 : k + 1
                    x = elem(A, lda, r, k)
                    setelem!(A, lda, r, k, elem(A, lda, kp, k))
                    setelem!(A, lda, kp, k, x)
                end
            end
            if kstep == 1
                # A := A - (1/d) x xᵀ on the rest, x the column k (scaled by 1/d after)
                m, r, o = upper ? (k - 1, 1, 0) : (n - k, k + 1, k)
                if m > 0
                    akk = elem(A, lda, k, k)
                    if !rook || abs(akk) >= sfmin
                        d = one(T) / akk
                        syr_at!(A, lda, upper, m, -d, r, k, o)
                        for i in r:r+m-1
                            setelem!(A, lda, i, k, d * elem(A, lda, i, k))
                        end
                    else
                        for i in r:r+m-1
                            setelem!(A, lda, i, k, elem(A, lda, i, k) / akk)
                        end
                        syr_at!(A, lda, upper, m, -akk, r, k, o)
                    end
                end
            elseif upper && k > 2
                # A := A - (W(k-1) W(k)) D⁻¹ (W(k-1) W(k))ᵀ on A(1:k-2, 1:k-2)
                d12 = elem(A, lda, k - 1, k)
                d22 = elem(A, lda, k - 1, k - 1) / d12
                d11 = elem(A, lda, k, k) / d12
                t = one(T) / (d11 * d22 - one(T))
                rook || (d12 = t / d12)
                for j in k-2:-1:1
                    a1, a0 = elem(A, lda, j, k - 1), elem(A, lda, j, k)
                    wkm1 = (rook ? t : d12) * (d11 * a1 - a0)
                    wk = (rook ? t : d12) * (d22 * a0 - a1)
                    for i in j:-1:1
                        v = rook ? elem(A, lda, i, j) - (elem(A, lda, i, k) / d12) * wk - (elem(A, lda, i, k - 1) / d12) * wkm1 :
                                   elem(A, lda, i, j) - elem(A, lda, i, k) * wk - elem(A, lda, i, k - 1) * wkm1
                        setelem!(A, lda, i, j, v)
                    end
                    setelem!(A, lda, j, k, rook ? wk / d12 : wk)
                    setelem!(A, lda, j, k - 1, rook ? wkm1 / d12 : wkm1)
                end
            elseif !upper && k < n - 1
                d21 = elem(A, lda, k + 1, k)
                d11 = elem(A, lda, k + 1, k + 1) / d21
                d22 = elem(A, lda, k, k) / d21
                t = one(T) / (d11 * d22 - one(T))
                rook || (d21 = t / d21)
                for j in k+2:n
                    a0, a1 = elem(A, lda, j, k), elem(A, lda, j, k + 1)
                    wk = (rook ? t : d21) * (d11 * a0 - a1)
                    wkp1 = (rook ? t : d21) * (d22 * a1 - a0)
                    for i in j:n
                        v = rook ? elem(A, lda, i, j) - (elem(A, lda, i, k) / d21) * wk - (elem(A, lda, i, k + 1) / d21) * wkp1 :
                                   elem(A, lda, i, j) - elem(A, lda, i, k) * wk - elem(A, lda, i, k + 1) * wkp1
                        setelem!(A, lda, i, j, v)
                    end
                    setelem!(A, lda, j, k, rook ? wk / d21 : wk)
                    setelem!(A, lda, j, k + 1, rook ? wkp1 / d21 : wkp1)
                end
            end
        end
        # the interchanges: kp of a 1×1 block; of a 2×2 one, -kp on both (Bunch-Kaufman) or
        # the two of rook pivoting
        if kstep == 1
            st!(ipiv, k, kp)
        else
            st!(ipiv, k, rook ? -p : -kp)
            st!(ipiv, upper ? k - 1 : k + 1, -kp)
        end
        k = upper ? k - kstep : k + kstep
    end
    setinfo!(info, inf)
end

"`sytrf` (`rook` false) and `sytrf_rook`: unblocked (a workspace query where `lwork` is -1)."
function sytrf!(uplo::UInt8, n::Int, A::ArrayArg{T}, lda::Int, ipiv::ArrayArg{Int},
                work::ArrayArg{T}, lwork::Int, info, rook::Bool=false) where {T}
    if lwork == -1
        st!(work, 1, T(max(1, n)))
        setinfo!(info, 0)
        return
    end
    sytf2!(uplo, n, A, lda, ipiv, info, rook)
end
sytrf_rook!(uplo::UInt8, n::Int, A::ArrayArg{T}, lda::Int, ipiv::ArrayArg{Int},
            work::ArrayArg{T}, lwork::Int, info) where {T} = sytrf!(uplo, n, A, lda, ipiv, work, lwork, info, true)

swaprhs!(B, ldb::Int, p::Int, q::Int, nrhs::Int) = p == q || swaprows!(B, ldb, p, q, nrhs)

# B(rows r .+ (0:m-1), :) -= A(r:r+m-1, c) * B(k, :)  (`dger`)
function ger_rhs!(B::ArrayArg{T}, ldb::Int, A::ArrayArg{T}, lda::Int, m::Int, r::Int, c::Int, k::Int, nrhs::Int) where {T}
    for j in 1:nrhs
        t = -elem(B, ldb, k, j)
        for i in 0:m-1
            setelem!(B, ldb, r + i, j, elem(B, ldb, r + i, j) + elem(A, lda, r + i, c) * t)
        end
    end
end
# B(k, :) -= A(r:r+m-1, c)ᵀ B(r:r+m-1, :)  (`dgemv` of Bᵀ)
function gemv_rhs!(B::ArrayArg{T}, ldb::Int, A::ArrayArg{T}, lda::Int, m::Int, r::Int, c::Int, k::Int, nrhs::Int) where {T}
    for j in 1:nrhs
        t = zero(T)
        for i in 0:m-1
            t += elem(B, ldb, r + i, j) * elem(A, lda, r + i, c)
        end
        setelem!(B, ldb, k, j, elem(B, ldb, k, j) - t)
    end
end
# the 2×2 block of D at rows (a, b), its off-diagonal element A(a, b) of the stored triangle
function solve2!(B::ArrayArg{T}, ldb::Int, A::ArrayArg{T}, lda::Int, a::Int, b::Int, offd::T, nrhs::Int) where {T}
    akm1 = elem(A, lda, a, a) / offd
    ak = elem(A, lda, b, b) / offd
    denom = akm1 * ak - one(T)
    for j in 1:nrhs
        bkm1 = elem(B, ldb, a, j) / offd
        bk = elem(B, ldb, b, j) / offd
        setelem!(B, ldb, a, j, (ak * bkm1 - bk) / denom)
        setelem!(B, ldb, b, j, (akm1 * bk - bkm1) / denom)
    end
end

"""`sytrs` (`rook` false) and `sytrs_rook`: solve A X = B with the factors of `sytrf` (or
`sytrf_rook`), X overwriting B."""
function sytrs!(uplo::UInt8, n::Int, nrhs::Int, A::ArrayArg{T}, lda::Int, ipiv::ArrayArg{Int},
                B::ArrayArg{T}, ldb::Int, info, rook::Bool=false) where {T}
    setinfo!(info, 0)
    if isupper(uplo)
        # U D X = B, then Uᵀ X = B
        k = n
        while k >= 1
            if ld(ipiv, k) > 0
                swaprhs!(B, ldb, k, ld(ipiv, k), nrhs)
                ger_rhs!(B, ldb, A, lda, k - 1, 1, k, k, nrhs)
                d = one(T) / elem(A, lda, k, k)
                for j in 1:nrhs
                    setelem!(B, ldb, k, j, d * elem(B, ldb, k, j))
                end
                k -= 1
            else
                swaprhs!(B, ldb, rook ? k : k - 1, -ld(ipiv, k), nrhs)
                rook && swaprhs!(B, ldb, k - 1, -ld(ipiv, k - 1), nrhs)
                ger_rhs!(B, ldb, A, lda, k - 2, 1, k, k, nrhs)
                ger_rhs!(B, ldb, A, lda, k - 2, 1, k - 1, k - 1, nrhs)
                solve2!(B, ldb, A, lda, k - 1, k, elem(A, lda, k - 1, k), nrhs)
                k -= 2
            end
        end
        k = 1
        while k <= n
            if ld(ipiv, k) > 0
                gemv_rhs!(B, ldb, A, lda, k - 1, 1, k, k, nrhs)
                swaprhs!(B, ldb, k, ld(ipiv, k), nrhs)
                k += 1
            else
                gemv_rhs!(B, ldb, A, lda, k - 1, 1, k, k, nrhs)
                gemv_rhs!(B, ldb, A, lda, k - 1, 1, k + 1, k + 1, nrhs)
                swaprhs!(B, ldb, k, -ld(ipiv, k), nrhs)
                rook && swaprhs!(B, ldb, k + 1, -ld(ipiv, k + 1), nrhs)
                k += 2
            end
        end
    else
        # L D X = B, then Lᵀ X = B
        k = 1
        while k <= n
            if ld(ipiv, k) > 0
                swaprhs!(B, ldb, k, ld(ipiv, k), nrhs)
                ger_rhs!(B, ldb, A, lda, n - k, k + 1, k, k, nrhs)
                d = one(T) / elem(A, lda, k, k)
                for j in 1:nrhs
                    setelem!(B, ldb, k, j, d * elem(B, ldb, k, j))
                end
                k += 1
            else
                swaprhs!(B, ldb, rook ? k : k + 1, -ld(ipiv, k), nrhs)
                rook && swaprhs!(B, ldb, k + 1, -ld(ipiv, k + 1), nrhs)
                ger_rhs!(B, ldb, A, lda, n - k - 1, k + 2, k, k, nrhs)
                ger_rhs!(B, ldb, A, lda, n - k - 1, k + 2, k + 1, k + 1, nrhs)
                solve2!(B, ldb, A, lda, k, k + 1, elem(A, lda, k + 1, k), nrhs)
                k += 2
            end
        end
        k = n
        while k >= 1
            if ld(ipiv, k) > 0
                gemv_rhs!(B, ldb, A, lda, n - k, k + 1, k, k, nrhs)
                swaprhs!(B, ldb, k, ld(ipiv, k), nrhs)
                k -= 1
            else
                gemv_rhs!(B, ldb, A, lda, n - k, k + 1, k, k, nrhs)
                gemv_rhs!(B, ldb, A, lda, n - k, k + 1, k - 1, k - 1, nrhs)
                swaprhs!(B, ldb, k, -ld(ipiv, k), nrhs)
                rook && swaprhs!(B, ldb, k - 1, -ld(ipiv, k - 1), nrhs)
                k -= 2
            end
        end
    end
end
sytrs_rook!(uplo::UInt8, n::Int, nrhs::Int, A::ArrayArg{T}, lda::Int, ipiv::ArrayArg{Int},
            B::ArrayArg{T}, ldb::Int, info) where {T} = sytrs!(uplo, n, nrhs, A, lda, ipiv, B, ldb, info, true)

end
