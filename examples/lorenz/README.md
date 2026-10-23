# Lorenz demo

OrdinaryDiffEq's `Tsit5` solving the Lorenz system, compiled to WebAssembly GC, in a page
with sliders for σ, ρ, β and x₀.

The integrator is built natively when the module is compiled (`model.jl`) and serialized
into it, as a juliac build would: the exported functions set the parameters and the initial
condition, `reinit!` and `solve!`, and read the saved points.

```
julia +1.13 --project=. -e 'using Pkg; Pkg.instantiate()'
julia +1.13 --project=. build.jl     # lorenz.wasm
julia +1.13 --project=. page.jl      # lorenz.html, with the optimized module embedded
node --experimental-wasm-exnref run.mjs lorenz.wasm   # solve and time in Node.js 24
```

`LocalPreferences.toml` sets SciMLLogging's `logging_backend = "core"` preference (as
juliac builds use), which the code needs to be trim-safe.
