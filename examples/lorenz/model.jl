# The Lorenz system solved by OrdinaryDiffEq's Tsit5, compiled to WebAssembly.
#
# As in a juliac build, the integrator is built at compile time (natively) and serialized
# into the module; the exported functions set the parameters and the initial condition,
# re-solve, and read the trajectory.

using OrdinaryDiffEqTsit5, SciMLBase, StaticArrays, SciMLLogging

lorenz(u, p, t) = SVector{3,Float64}(p[1] * (u[2] - u[1]),
                                     u[1] * (p[2] - u[3]) - u[2],
                                     u[1] * u[2] - p[3] * u[3])

const T_END = 40.0
const PROB = ODEProblem(ODEFunction{false,SciMLBase.FullSpecialize}(lorenz),
                        SVector{3,Float64}(1.0, 1.0, 1.0), (0.0, T_END), (10.0, 28.0, 8 / 3))
const INTEG = init(PROB, Tsit5(); saveat=0.01, abstol=1e-8, reltol=1e-8,
                   verbose=SciMLLogging.None(), initializealg=SciMLBase.NoInit())

"Solve with the parameters σ, ρ, β from (x0, 1, 1); returns the number of points."
function lorenz_solve(σ::Float64, ρ::Float64, β::Float64, x0::Float64)::Int32
    INTEG.p = (σ, ρ, β)
    SciMLBase.reinit!(INTEG, SVector{3,Float64}(x0, 1.0, 1.0))
    SciMLBase.solve!(INTEG)
    return Int32(length(INTEG.sol.u))
end

"The coordinate `k` (1-3) of the point `i` of the last solution."
lorenz_point(i::Int32, k::Int32)::Float64 = INTEG.sol.u[i][k]

"The number of accepted steps of the last solve."
lorenz_steps()::Int32 = Int32(INTEG.stats.naccept)

const ENTRIES = [(lorenz_solve, (Float64, Float64, Float64, Float64)),
                 (lorenz_point, (Int32, Int32)), (lorenz_steps, ())]
