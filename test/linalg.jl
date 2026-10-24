# LinearAlgebra: BLAS and LAPACK implemented in the runtime (src/runtime/blas.jl, lapack.jl)

using LinearAlgebra

# a well-conditioned matrix (results within rounding of an optimized BLAS's)
wmat(m, n, s) = [1.0 / (a + b - 1) + (a == b ? 2.0 : 0.0) + 0.1 * sin(a * 3.7 + b * 1.3 + s) for a in 1:m, b in 1:n]
vec4(x) = (x[1], x[2], x[3], x[4])

la_dot(n::Int) = (v = [sin(k + 0.5n) for k in 1:10n]; w = [cos(1.5k) for k in 1:10n];
                  (dot(v, w), norm(v), norm(v, 1), Float64(LinearAlgebra.BLAS.iamax(v))))
la_gemm(n::Int) = (A = wmat(n + 3, 5, 0.1); B = wmat(5, 4, 0.7); C = A * B; D = A' * A; E = A * A';
                   (C[1, 1], C[end, end], D[2, 3], E[end, 1], sum(A * ones(5)), sum(A' * ones(n + 3))))
la_gemm32(n::Int) = (A = Float32.(wmat(n + 3, 5, 0.1)); B = Float32.(wmat(5, 4, 0.7)); C = A * B;
                     (Float64(C[1, 1]), Float64(C[end, end]), Float64(sum(A' * A))))
la_mul!(n::Int) = (A = wmat(5, 4, 0.3); B = wmat(4, 6, 0.2); C = ones(5, 6); mul!(C, A, B, 2.0, 0.5);
                   x = ones(5); mul!(x, A, ones(4), 1.0, 3.0); (C[1, 1], C[5, 6], x[1], x[5]))
la_tri(n::Int) = (A = wmat(5, 5, 0.1); b = [1.0 * k for k in 1:5]; B = wmat(5, 3, 0.4);
                  (sum(UpperTriangular(A) \ b), sum(LowerTriangular(A) \ B), sum(UpperTriangular(A)' \ b),
                   sum(UpperTriangular(A) * b), sum(B' / UpperTriangular(A)), sum(Symmetric(A) * b), sum(inv(UpperTriangular(A)))))
la_lu(n::Int) = (A = wmat(n + 3, n + 3, 0.3); b = [1.0 * k for k in 1:n+3]; F = lu(A);
                 (det(A), sum(A \ b), sum(inv(A)), sum(F.L), sum(F.U), Float64(sum(F.p)), logabsdet(A)[1]))
la_chol(n::Int) = (A = wmat(n + 3, n + 3, 0.2); A = A' * A; b = [1.0 * k for k in 1:n+3]; C = cholesky(A);
                   (sum(C.U), sum(C \ b), det(C), Float64(isposdef(A)), Float64(isposdef(-A))))
la_qr(n::Int) = (A = wmat(n + 4, 4, 0.3); b = [1.0 * k for k in 1:n+4]; F = qr(A);
                 (vec4(F \ b)..., abs(F.R[1, 1]), abs(F.R[4, 4]), sum(abs.(F.Q' * b))))
la_qrp(n::Int) = (A = wmat(n + 4, 4, 0.3); b = [1.0 * k for k in 1:n+4]; F = qr(A, ColumnNorm());
                  (vec4(F \ b)..., Float64(F.p[1]), abs(F.R[1, 1])))
la_lsq(n::Int) = (A = wmat(3, 5 + n, 0.2); x = A \ [1.0, 2.0, 3.0]; (x[1], x[2], x[end], sum(x)))
la_rankdef(n::Int) = (A = wmat(6, 3, 0.1); A = hcat(A, A[:, 1] + A[:, 2]); x = A \ [1.0 * k for k in 1:6]; vec4(x))

# eigenvectors and singular vectors are defined up to sign: compared by their absolute values
la_eigen(n::Int) = (A = wmat(n + 3, n + 3, 0.2); S = Symmetric(A + A'); E = eigen(S); w = eigvals(S);
                    (w[1], w[end], sum(w), sum(abs.(E.vectors)), abs(E.vectors[1, 1]), sum(eigvals(S, 1:2))))
la_svd(n::Int) = (A = wmat(n + 4, 3, 0.4); F = svd(A); s = svdvals(A);
                  (s[1], s[end], F.S[2], sum(abs.(F.U)), sum(abs.(F.Vt)), sum(abs.(svd(A'; full=true).U)),
                   Float64(rank(A)), opnorm(A), cond(A), sum(pinv(A))))
# symmetric indefinite (Bunch-Kaufman, its rook variant): a zero diagonal makes 2×2 pivots
function la_bk(n::Int, upper::Bool, rook::Bool)
    uplo = upper ? :U : :L
    A = wmat(n + 4, n + 4, 0.5); B = A + A'
    for k in 1:2:n+4
        B[k, k] = 0.0
    end
    S = Symmetric(B, uplo); b = [1.0 * k for k in 1:n+4]
    F = bunchkaufman(S, rook)
    return (sum(F \ b), det(F), sum(S \ b), sum(F \ [b 2b]))
end
# (the full Vt of a wide matrix: its first rows only, the rest a basis of its null space)
la_gesvd(n::Int) = (A = wmat(n + 4, 3, 0.4); F = svd(A; alg=LinearAlgebra.QRIteration());
                    G = svd(A'; full=true, alg=LinearAlgebra.QRIteration());
                    (F.S[1], F.S[end], sum(abs.(F.U)), sum(abs.(F.Vt)), sum(abs.(G.U)), sum(abs.(G.Vt[1:3, :]))))

@testset "linear algebra" begin
    for n in 0:3, upper in (true, false), rook in (false, true)
        @wtest_approx la_bk(n, upper, rook)
    end
    for n in 1:2
        @wtest_approx la_gesvd(n)
    end
    for n in 1:3
        @wtest_approx la_eigen(n)
        @wtest_approx la_svd(n)
    end
    for n in 1:3
        @wtest_approx la_dot(n)
        @wtest_approx la_gemm(n)
        @wtest_approx la_lu(n)
        @wtest_approx la_chol(n)
        @wtest_approx la_qr(n - 1)
        @wtest_approx la_qrp(n - 1)
        @wtest_approx la_lsq(n - 1)
    end
    @wtest la_gemm32(1)
    @wtest_approx la_mul!(1)
    @wtest_approx la_tri(1)
    @wtest_approx la_rankdef(1)
end
