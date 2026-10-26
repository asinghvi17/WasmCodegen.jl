module LorenzProgram

using OrdinaryDiffEqTsit5, StaticArrays, SciMLLogging
using OrdinaryDiffEqTsit5: SciMLBase
using DiffEqBase: DEVerbosity


lorenz(u, p, t) = SVector{3,Float64}(p[1] * (u[2] - u[1]),
    u[1] * (p[2] - u[3]) - u[2], u[1] * u[2] - p[3] * u[3])

# Four time units keep the full trajectory comparison ahead of chaotic divergence.
const CONFIG = (; t_end=4.0, saveat=0.01)
const DEFAULT_P = (10.0, 28.0, 8 / 3)

function setup(config)
    prob = ODEProblem(ODEFunction{false,SciMLBase.FullSpecialize}(lorenz),
        SVector{3,Float64}(1.0, 1.0, 1.0), (0.0, config.t_end), DEFAULT_P)
    return init(prob, Tsit5(); saveat=config.saveat, abstol=1e-8, reltol=1e-8,
        verbose=DEVerbosity(SciMLLogging.None()), initializealg=SciMLBase.NoInit())
end

function reset!(s)
    s.p = DEFAULT_P
    SciMLBase.reinit!(s, SVector{3,Float64}(1.0, 1.0, 1.0))
    return nothing
end

function solve!(s, σ::Float64, ρ::Float64, β::Float64, x0::Float64)::Int32
    s.p = (σ, ρ, β)
    SciMLBase.reinit!(s, SVector{3,Float64}(x0, 1.0, 1.0))
    SciMLBase.solve!(s)
    return Int32(length(s.sol.u))
end

point(s, i::Int32, k::Int32)::Float64 = s.sol.u[i][k]

function spec(n=4)
    (; ProgramSpec, BakedPool, ExportSpec) = Main.ProgramBuild
    ProgramSpec(; name="lorenz", source=@__FILE__, setup, config=CONFIG, instances=BakedPool(n),
    reset=reset!, exports=[
        ExportSpec(:solve, solve!, (Float64, Float64, Float64, Float64); returns=Int32),
        ExportSpec(:point, point, (Int32, Int32); returns=Float64)])
end

end
