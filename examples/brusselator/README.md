# Brusselator demo

A stiff reaction-diffusion system, the 1D Brusselator on 32 points (64 unknowns), solved by
OrdinaryDiffEq's `Rodas5P` with an analytic banded Jacobian, compiled to WebAssembly GC. Each
step solves linear systems with W = I/(γ dt) - J, by one of three of LinearSolve's pure-Julia
solvers: `GenericLUFactorization` (dense, blocked LU), `PureKLUFactorization` (sparse KLU on
the band's pattern) or `KrylovJL_GMRES`.

```
julia +1.13 --project=. -e 'using Pkg; Pkg.instantiate()'
julia +1.13 --project=. native.jl    # each solver natively: counts, times, agreement
julia +1.13 --project=. build.jl     # brusselator.wasm
node check.mjs                       # the same in Node.js 24, with the same checksums
julia +1.13 --project=. page.jl      # brusselator.html: sliders, the module embedded
```

As in a juliac build, the three integrators (and their LinearSolve caches) are built at
compile time and serialized into the module; `bz_solve` sets the parameters, re-initializes
and re-solves one of them. The module compiles with WasmCodegen's default configuration
(`trim = :safe`), with SciMLLogging's default logging backend. After `wasm-opt` it is about
1 MB; the default case (109 steps, 872 linear solves) takes 8 to 22 ms in Node.js depending
on the solver, against 1.6 to 4.9 ms natively. The step counts and the solutions are the
native ones (GMRES's to its tolerance).
