# Julia's parser in WebAssembly

JuliaSyntax, the parser that ships with Julia 1.13 (`Base.JuliaSyntax`), compiled to
WebAssembly GC, unchanged, and a page to try it.

```
julia +1.13 --project=. -e 'using Pkg; Pkg.instantiate()'
julia +1.13 --project=. build.jl        # parser.wasm (entry points in parser.jl)
julia +1.13 --project=. reference.jl    # the native parser's output on a corpus
node --experimental-wasm-exnref check.mjs   # the module's output must match, node for node
julia +1.13 --project=. page.jl         # parser.html
```

The page writes the source's UTF-8 bytes into the module, parses, and reads back the
parser's raw output: the tokens and the ranges of the green tree in postorder, with their
kinds, flags and spans, and the diagnostics. It builds the tree from them as JuliaSyntax's
`build_tree` does. Only numbers cross the boundary.

The corpus of `reference.jl` is a set of snippets, syntax errors included, and three files
of Base and JuliaSyntax (300 KB): the module's output matches the native parser's on all
of it, and parses it in about 100 ms in Node.js.

What WebAssembly lacks, the runtime provides: the lexer's Unicode properties come from
tables computed from the native libraries, and float literals are parsed by Parsers.jl.
JuliaSyntax passes its subparsers as `down::Function`; WasmCodegen specializes such calls
(`compilesig_invokes = false`), which juliac's verifier rejects otherwise.
