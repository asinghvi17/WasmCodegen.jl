# Build oscillator.wasm from model.jl: julia +1.13 --project=. build.jl
using WasmCodegen
include("model.jl")

# compiled first: the integrator is serialized as `init` left it (one saved point)
c = WasmCodegen.with_trim_patches() do _, _
    WasmCodegen.compile([WasmCodegen.Entry(f, at) for (f, at) in ENTRIES])
end
write(joinpath(@__DIR__, "oscillator.wasm"), c.bytes)
println("oscillator.wasm: $(length(c.bytes)) bytes, $(length(c.cgm.funcs)) functions, ",
        "$(length(c.cgm.image.globals)) serialized objects")

# the reference run, natively (check.mjs compares the module with it)
osc_solve(1.0, 10.0, 0.5, 1.0, 2.0, 1.0, 0.0)
n = Int32(length(INTEG.sol.u))
ref = (x = osc_state(n, Int32(1)), v = osc_state(n, Int32(2)), E = osc_observed(n, Int32(1)),
       steps = osc_steps(), points = n)
println("native: ", ref)
native_ms = minimum(@elapsed(osc_solve(1.0, 10.0, 0.5, 1.0, 2.0, 1.0, 0.0)) for _ in 1:20) * 1000
write(joinpath(@__DIR__, "stats.txt"),
      "functions=$(length(c.cgm.funcs))\nobjects=$(length(c.cgm.image.globals))\n",
      "x=$(ref.x)\nv=$(ref.v)\nE=$(ref.E)\nsteps=$(ref.steps)\npoints=$(ref.points)\n",
      "native_ms=$(native_ms)\n")
