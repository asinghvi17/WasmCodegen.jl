# WasmCodegen.jl

[![CI](https://github.com/gbaraldi/WasmCodegen.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/gbaraldi/WasmCodegen.jl/actions/workflows/CI.yml)

A compiler from Julia to WebAssembly with garbage collection (WasmGC), working like
`juliac --trim`. From entry points, it collects the closed world of code they can run,
using Julia's own inference. It compiles that code to a Wasm module and serializes the
Julia objects the code refers to into the module. A program can build its data natively at
compile time (an `ODEProblem`, an integrator after `init`, a lookup table), and the module
starts with that data instead of the code that built it.

No Julia runtime is linked. WasmGC provides allocation and garbage collection, and
generated code handles object layout and type tags. What libjulia's C code does
otherwise (IO, 128-bit arithmetic, `memmove`, random seeds) is a small runtime written in
Julia and compiled into the module on demand, over a few host imports.

**Status: experimental.** The supported subset is what `juliac --trim=safe` accepts: no
dynamic dispatch. Julia 1.13 is the main target, and 1.12 also works. Programs that run
today include OrdinaryDiffEq's `Tsit5` on an `ODEProblem` built at compile time, a
ModelingToolkit model, Random (bit-identical streams), printing to `stdout`, and the
programs of JuliaC.jl's tests (dispatch over concrete types, reductions, sorting,
concatenation). Exceptions trap: `try`/`catch` is not compiled yet.

## Example

```julia
using WasmCodegen

function f(n::Int)
    v = [sin(i * 0.1) for i in 1:n]
    println(Core.stdout, "sum = ", sum(v))
    return maximum(v)
end

c = WasmCodegen.compile(f, (Int,))           # or compile([(f, (Int,)), (g, (Float64,))])
write("f.wasm", c.bytes)
```

```js
// node --experimental-wasm-exnref run.mjs
import fs from 'node:fs';
const bytes = fs.readFileSync('f.wasm');
let out = [];
const julia = {
  write_byte: (fd, b) => out.push(b),     // Core.stdout / Core.stderr, as bytes
  entropy: () => BigInt.asIntN(64, crypto.getRandomValues(new BigUint64Array(1))[0]),
};
const { instance } = await WebAssembly.instantiate(bytes, { julia });
console.log(instance.exports.f(100n));      // Int is an i64: a BigInt
process.stdout.write(new TextDecoder().decode(new Uint8Array(out)));
```

`compile` throws `UnsupportedConstructs` with the statements it cannot compile and the
method instances they are in, as juliac's verifier reports what it cannot trim.
`examples/lorenz` builds a page solving the Lorenz system with adjustable parameters.

## How it works

- **The program's world.** The program is inferred in a world with juliac's trim patches
  (method redefinitions from JuliaC.jl) and the pseudo-runtime's own (`src/trim`), such
  as IO through a host import instead of libuv. The patches are deleted afterwards. The
  compiler itself runs in the world it was loaded in.
- **Collecting.** `Core.Compiler.compile!` with a Wasm interpreter, as juliac's
  `typeinf_ext_toplevel` does, so the code compiled is the code juliac compiles.
- **Structuring.** Each function's IR is turned into structured control flow by
  [IRStructurizer.jl](https://github.com/maleadt/IRStructurizer.jl). For now this is the
  `eh-tryop` branch of [a fork](https://github.com/gbaraldi/IRStructurizer.jl/tree/eh-tryop),
  which adds structured exception handling; `Project.toml` installs it from there.
- **Emitting.** Values follow JuliaCodegen.jl's representations. Isbits values are inline
  (Wasm locals, multi-value returns), everything else is a WasmGC object with a type tag.
  `Memory` is a Wasm array, and Base's `Array` code compiles from its Julia source.
  Pointers are an address plus the object they point into, so Base's pointer code works.
  Modules are built and validated with
  [WasmBuilder.jl](https://github.com/gbaraldi/WasmBuilder.jl).
- **The image.** Constants and global variables, and everything reachable from them,
  become immutable globals in the module, with identity preserved and cycles completed by
  the start function.

[DESIGN.md](DESIGN.md) describes each part.

## Tests

`Pkg.test()` compiles each test program, runs it in Node.js 24 (`NodeJS_24_jll`), and
compares the result with native Julia. Modules are validated by WasmBuilder, and also by
`wasm-tools` when it is installed.
