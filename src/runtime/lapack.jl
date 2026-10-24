# LAPACK, for what LinearAlgebra's factorizations call: LU (`getrf`, `getrs`, `getri`),
# Cholesky (`potrf`, `potrs`), triangular solves (`trtrs`) and copies (`lacpy`), on real
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

end
