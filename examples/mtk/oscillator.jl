# A ModelingToolkit model compiled to Wasm (trim = :safe), compared with native Julia:
#
#     julia +1.13 --project=. oscillator.jl
#
# MTK builds the system and its problem at build time, as FMUGeneration does for juliac:
# `eval_expression = true` makes its generated functions ordinary Julia functions (instead
# of RuntimeGeneratedFunctions). The integrator of a SciMLBase problem of the generated
# right-hand side (`FullSpecialize`) is built at build time too, and serialized into the
# module; the symbolic system itself is not part of the program (or of the Wasm image).

# the test harness: compile, run in Node.js, compare with native Julia
include(joinpath(@__DIR__, "..", "..", "test", "harness.jl"))
using ModelingToolkit, OrdinaryDiffEqTsit5, SciMLBase, SciMLLogging, CommonSolve
using SymbolicIndexingInterface
using ModelingToolkit: t_nounits as t, D_nounits as D

# a forced, damped oscillator: the spring force, the acceleration and the energy are
# algebraic, eliminated by mtkcompile (observed)
@parameters m = 1.0 k = 10.0 c = 0.5 F = 1.0 ω = 2.0
@variables x(t) = 1.0 v(t) = 0.0 Fs(t) a(t) E(t)
eqs = [D(x) ~ v,
       Fs ~ -k * x - c * v + F * sin(ω * t),
       a ~ Fs / m,
       D(v) ~ a,
       E ~ m * v^2 / 2 + k * x^2 / 2]
@named osc = System(eqs, t)
const SYS = mtkcompile(osc)
const MTKPROB = ODEProblem(SYS, [], (0.0, 10.0); eval_expression = true, eval_module = @__MODULE__)

println("unknowns: ", unknowns(SYS), "  observed: ", [eq.lhs for eq in ModelingToolkit.observed(SYS)])
println("rhs: ", typeof(MTKPROB.f.f).name.wrapper, "  p: ", typeof(MTKPROB.p).name.wrapper)

const RHS = ODEFunction{true, SciMLBase.FullSpecialize}(MTKPROB.f.f)
const U0 = copy(MTKPROB.u0)
const P = MTKPROB.p
const SET_K = setp(SYS, SYS.k)
const ENERGY = ModelingToolkit.build_explicit_observed_function(SYS, SYS.E;
    eval_expression = true, eval_module = @__MODULE__)
const XIDX = variable_index(SYS, SYS.x)

# As FMUGeneration's FMUs do (and juliac requires: `solve` itself deep-copies the
# parameters, through calls juliac's verifier cannot resolve), the integrator is built at
# compile time, and the entry points re-initialize and re-solve it.
const INTEG = init(ODEProblem{true, SciMLBase.FullSpecialize}(RHS, copy(U0), (0.0, 10.0), P), Tsit5();
                   save_everystep = false, abstol = 1e-8, reltol = 1e-8,
                   verbose = SciMLLogging.None(), initializealg = SciMLBase.NoInit())

"x(T) for the spring constant `k` (set by MTK's parameter setter), the energy (an observed
variable) then, and the number of steps."
function mtk_run(T::Float64, k::Float64)
    SET_K(INTEG, k)
    SciMLBase.reinit!(INTEG, U0; tf = T)
    SciMLBase.solve!(INTEG)
    u = INTEG.u
    return (u[XIDX], ENERGY(u, INTEG.p, INTEG.t), INTEG.stats.naccept)
end

WasmCodegen.with_trim_patches() do _, _
    for (f, args) in ((mtk_run, (10.0, 10.0)), (mtk_run, (10.0, 3.0)), (mtk_run, (5.0, 25.0)))
        local c
        tm = @elapsed c = try
            WasmCodegen.compile(f, map(typeof, args))   # trim = :safe
        catch e
            println("== $f: does not compile (trim = :safe)")
            println(join(first(split(sprint(showerror, e), "\n"), 40), "\n"))
            nothing
        end
        c === nothing && continue
        println("== $f$(args): compiled in $(round(tm, digits=1)) s: $(length(c.bytes)) bytes, ",
                "$(length(c.cgm.funcs)) functions, $(length(c.cgm.image.globals)) image objects")
        expected = Base.invokelatest(f, args...)
        got = wasm_run(c, string(nameof(f)), args...; rettype=typeof(expected))
        println("  native ", expected, "\n  wasm   ", got)
    end
end
