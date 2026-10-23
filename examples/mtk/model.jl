# The forced, damped oscillator of the web page, written with ModelingToolkit and compiled to
# WebAssembly.
#
# As in a juliac build of an MTK model (FMUGeneration.jl), everything symbolic happens at
# build time: MTK simplifies the system and generates its right-hand side and observed
# functions as ordinary Julia functions (`eval_expression = true`), and the integrator is
# built here and serialized into the module. The exported functions set the parameters with
# MTK's setter, re-initialize and re-solve the integrator, and read the trajectory.

using ModelingToolkit, OrdinaryDiffEqTsit5, SciMLBase, SciMLLogging
using SymbolicIndexingInterface
using ModelingToolkit: t_nounits as t, D_nounits as D

@parameters m = 1.0 k = 10.0 c = 0.5 F = 1.0 ω = 2.0
@variables x(t) = 1.0 v(t) = 0.0 Fs(t) a(t) E(t)
eqs = [D(x) ~ v,
       Fs ~ -k * x - c * v + F * sin(ω * t),
       a ~ Fs / m,
       D(v) ~ a,
       E ~ m * v^2 / 2 + k * x^2 / 2]
@named oscillator = System(eqs, t)
const SYS = mtkcompile(oscillator)

const T_END = 30.0
const MTKPROB = ODEProblem(SYS, [], (0.0, T_END); eval_expression = true, eval_module = @__MODULE__)
const RHS = ODEFunction{true, SciMLBase.FullSpecialize}(MTKPROB.f.f)
const INTEG = init(ODEProblem{true, SciMLBase.FullSpecialize}(RHS, copy(MTKPROB.u0), (0.0, T_END), MTKPROB.p),
                   Tsit5(); saveat = 0.02, abstol = 1e-8, reltol = 1e-8,
                   verbose = SciMLLogging.None(), initializealg = SciMLBase.NoInit())

# MTK's accessors, resolved at build time: a setter of the five parameters (over a tuple,
# which stays type-stable), the positions of the states, and the observed functions
const SET_PARAMS = setp(SYS, (SYS.m, SYS.k, SYS.c, SYS.F, SYS.ω))
const XIDX = variable_index(SYS, SYS.x)
const VIDX = variable_index(SYS, SYS.v)
observed_fn(sym) = ModelingToolkit.build_explicit_observed_function(SYS, sym;
    eval_expression = true, eval_module = @__MODULE__)
const ENERGY = observed_fn(SYS.E)
const FORCE = observed_fn(SYS.Fs)
const ACCEL = observed_fn(SYS.a)
const U0 = zeros(2)

"Solve from x(0) = x0, v(0) = v0 with the parameters given; returns the number of points."
function osc_solve(m::Float64, k::Float64, c::Float64, F::Float64, ω::Float64,
                   x0::Float64, v0::Float64)::Int32
    SET_PARAMS(INTEG, (m, k, c, F, ω))
    U0[XIDX] = x0
    U0[VIDX] = v0
    SciMLBase.reinit!(INTEG, U0)
    INTEG.stats.naccept = 0    # reinit! keeps counting
    SciMLBase.solve!(INTEG)
    return Int32(length(INTEG.sol.u))
end

"The time of the point `i` of the last solution."
osc_time(i::Int32)::Float64 = INTEG.sol.t[i]

"The state `j` (1: x, 2: v) of the point `i`."
osc_state(i::Int32, j::Int32)::Float64 = INTEG.sol.u[i][j == 1 ? XIDX : VIDX]

"The observed variable `j` (1: energy E, 2: force Fs, 3: acceleration a) at the point `i`."
function osc_observed(i::Int32, j::Int32)::Float64
    u, p, τ = INTEG.sol.u[i], INTEG.p, INTEG.sol.t[i]
    return j == 1 ? ENERGY(u, p, τ) : j == 2 ? FORCE(u, p, τ) : ACCEL(u, p, τ)
end

"The number of accepted steps of the last solve."
osc_steps()::Int32 = Int32(INTEG.stats.naccept)

const ENTRIES = [(osc_solve, (Float64, Float64, Float64, Float64, Float64, Float64, Float64)),
                 (osc_time, (Int32,)), (osc_state, (Int32, Int32)),
                 (osc_observed, (Int32, Int32)), (osc_steps, ())]
