# The 1D Brusselator (a stiff reaction-diffusion system) solved by OrdinaryDiffEq's Rodas5P,
# its linear systems by LinearSolve, compiled to WebAssembly.
#
#   u_t = A + u²v - (B + 1)u + α u_xx
#   v_t = Bu - u²v + α v_xx          on 0 < x < 1, u = A and v = B/A at the ends
#
# on N interior points, the unknowns interleaved (u₁, v₁, u₂, v₂, ...) so that the Jacobian
# is banded. Rodas5P solves a linear system with W = I/(γ dt) - J at each stage: here by
# three of LinearSolve's pure-Julia solvers, one integrator each, built at compile time (as in
# a juliac build) and serialized into the module.

using OrdinaryDiffEqRosenbrock, LinearSolve, SparseArrays, SciMLBase, SciMLLogging

const N = 32
const DX = 1 / (N + 1)
const T_END = 10.0
const SAVEAT = 0.05

@inline function brusselator_point(uv, i, A, B)
    u, v = uv[2i-1], uv[2i]
    ul = i == 1 ? A : uv[2i-3]
    ur = i == N ? A : uv[2i+1]
    vl = i == 1 ? B / A : uv[2i-2]
    vr = i == N ? B / A : uv[2i+2]
    return u, v, ul, ur, vl, vr
end

function brusselator!(du, uv, p, t)
    A, B, α = p
    c = α / DX^2
    @inbounds for i in 1:N
        u, v, ul, ur, vl, vr = brusselator_point(uv, i, A, B)
        du[2i-1] = A + u^2 * v - (B + 1) * u + c * (ul - 2u + ur)
        du[2i] = B * u - u^2 * v + c * (vl - 2v + vr)
    end
    return nothing
end

# the Jacobian's entries, written into a dense or a sparse matrix (of the band's pattern)
function brusselator_jac!(J, uv, p, t)
    A, B, α = p
    c = α / DX^2
    J isa SparseMatrixCSC ? fill!(nonzeros(J), 0.0) : fill!(J, 0.0)
    @inbounds for i in 1:N
        u, v = uv[2i-1], uv[2i]
        iu, iv = 2i - 1, 2i
        J[iu, iu] = 2u * v - (B + 1) - 2c
        J[iu, iv] = u^2
        J[iv, iu] = B - 2u * v
        J[iv, iv] = -u^2 - 2c
        if i > 1
            J[iu, iu-2] = c
            J[iv, iv-2] = c
        end
        if i < N
            J[iu, iu+2] = c
            J[iv, iv+2] = c
        end
    end
    return nothing
end

# (autonomous: no time derivative)
brusselator_tgrad!(dT, uv, p, t) = (fill!(dT, 0.0); nothing)

function band_pattern()
    I, J = Int[], Int[]
    for i in 1:N, (a, b) in ((0, 0), (0, 1), (1, 0), (1, 1))
        push!(I, 2i - 1 + a); push!(J, 2i - 1 + b)
    end
    for i in 1:N-1, k in 0:1
        push!(I, 2i - 1 + k); push!(J, 2i + 1 + k)
        push!(I, 2i + 1 + k); push!(J, 2i - 1 + k)
    end
    return sparse(I, J, zeros(length(I)), 2N, 2N)
end

initial_state(A, B, amp) = [isodd(k) ? A + amp * sin(2π * DX * ((k + 1) ÷ 2)) : B / A for k in 1:2N]

const P0 = (1.0, 3.0, 0.02)
const U0 = initial_state(1.0, 3.0, 1.0)

function integrator(linsolve, jac_prototype)
    f = ODEFunction{true,SciMLBase.FullSpecialize}(brusselator!; jac=brusselator_jac!,
                                                   tgrad=brusselator_tgrad!, jac_prototype)
    prob = ODEProblem{true,SciMLBase.FullSpecialize}(f, copy(U0), (0.0, T_END), P0)
    return init(prob, Rodas5P(; linsolve); saveat=SAVEAT, abstol=1e-6, reltol=1e-6,
                verbose=SciMLLogging.None(), initializealg=SciMLBase.NoInit())
end

const INTEG_LU = integrator(GenericLUFactorization(), nothing)          # dense W: blocked LU
const INTEG_KLU = integrator(PureKLUFactorization(), band_pattern())     # sparse W: KLU
const INTEG_GMRES = integrator(KrylovJL_GMRES(), band_pattern())        # sparse W: GMRES

const SOLVERS = ("GenericLUFactorization", "PureKLUFactorization", "KrylovJL_GMRES")

function solve_with!(integ, A, B, α, amp)
    integ.p = (A, B, α)
    SciMLBase.reinit!(integ, initial_state(A, B, amp))
    integ.stats.naccept = 0; integ.stats.nreject = 0; integ.stats.nw = 0
    integ.stats.njacs = 0; integ.stats.nsolve = 0; integ.stats.nf = 0
    SciMLBase.solve!(integ)
    return Int32(SciMLBase.successful_retcode(integ.sol.retcode) ? length(integ.sol.u) : -1)
end

"Solve with the linear solver `k` (1: dense LU, 2: KLU, 3: GMRES) and the parameters A, B,
α and the initial amplitude; returns the number of saved points (-1: the solve failed)."
function bz_solve(k::Int32, A::Float64, B::Float64, α::Float64, amp::Float64)::Int32
    k == 1 && return solve_with!(INTEG_LU, A, B, α, amp)
    k == 2 && return solve_with!(INTEG_KLU, A, B, α, amp)
    return solve_with!(INTEG_GMRES, A, B, α, amp)
end

sol_of(k) = k == 1 ? INTEG_LU.sol : k == 2 ? INTEG_KLU.sol : INTEG_GMRES.sol
stats_of(k) = k == 1 ? INTEG_LU.stats : k == 2 ? INTEG_KLU.stats : INTEG_GMRES.stats

"u (`c` = 1) or v (`c` = 2) at the grid point `j` of the saved point `i` of solver `k`'s solution."
bz_value(k::Int32, i::Int32, j::Int32, c::Int32)::Float64 = sol_of(k).u[i][2j-2+c]

"The time of the saved point `i`."
bz_time(k::Int32, i::Int32)::Float64 = sol_of(k).t[i]

"Solver `k`'s counts of its last solve: 1 accepted steps, 2 rejected, 3 W factorizations,
4 Jacobians, 5 linear solves, 6 right-hand sides."
function bz_stat(k::Int32, s::Int32)::Int32
    st = stats_of(k)
    v = s == 1 ? st.naccept : s == 2 ? st.nreject : s == 3 ? st.nw : s == 4 ? st.njacs :
        s == 5 ? st.nsolve : st.nf
    return Int32(v)
end

bz_n()::Int32 = Int32(N)

const ENTRIES = [(bz_solve, (Int32, Float64, Float64, Float64, Float64)),
                 (bz_value, (Int32, Int32, Int32, Int32)), (bz_time, (Int32, Int32)),
                 (bz_stat, (Int32, Int32)), (bz_n, ())]
