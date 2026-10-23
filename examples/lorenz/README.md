# Lorenz demo

OrdinaryDiffEq's `Tsit5` solving the Lorenz system, compiled to WebAssembly GC, in a page
with sliders for σ, ρ, β and x₀.

The integrator is built natively when the module is compiled (`model.jl`) and serialized
into it, as a juliac build would: the exported functions set the parameters and the initial
condition, `reinit!` and `solve!`, and read the saved points.

```
julia +1.13 --project=<env with OrdinaryDiffEqTsit5, StaticArrays, SciMLLogging, WasmCodegen> build.jl
julia +1.13 --project=<env> page.jl   # lorenz.html, with the optimized module embedded
node run.mjs lorenz.wasm              # solve and time in Node.js
```

The environment needs SciMLLogging's `logging_backend = "core"` preference (as juliac
builds use) for the code to be trim-safe.
