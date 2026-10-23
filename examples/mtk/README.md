# ModelingToolkit example

A forced, damped oscillator written with ModelingToolkit, compiled to WebAssembly GC with
`trim = :safe`, and compared with native Julia.

```
julia +1.13 --project=. -e 'using Pkg; Pkg.instantiate()'
julia +1.13 --project=. oscillator.jl
```

`mtkcompile` reduces the model to two states (`x`, `v`); the spring force, acceleration
and energy become observed variables. The entry point `mtk_run(T, k)` sets the spring
constant with MTK's own parameter setter (`setp`), re-initializes and re-solves the
integrator with `Tsit5`, and evaluates the energy through MTK's observed function.

The pattern is the one FMUGeneration.jl uses for juliac builds of MTK models:

- `eval_expression = true`, so the generated right-hand side and observed functions are
  ordinary Julia functions instead of RuntimeGeneratedFunctions;
- a plain `ODEFunction{true, FullSpecialize}` of the generated right-hand side, so the
  symbolic system is not reachable from the program;
- the integrator built at build time (`init`) and serialized into the module, with
  `reinit!`/`solve!` at run time. `solve` itself is not trim-safe for MTK problems:
  `OrdinaryDiffEq` copies the `MTKParameters` with `deepcopy`, which juliac's verifier
  rejects too.

Output on Julia 1.13 (results agree with native to the last digits; native Julia uses FMA,
Wasm has none):

```
== mtk_run(10.0, 10.0): compiled in 40.4 s: 179185 bytes, 77 functions, 200 image objects
  native (0.22063997958755244, 0.2514322173938296, 308)
  wasm   (0.22063997958755255, 0.2514322173938298, 308)
```
