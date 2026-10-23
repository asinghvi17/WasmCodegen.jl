# Build the demo page: julia --project=<env> page.jl (after build.jl)
using Base64, Binaryen_jll
include("model.jl")

dir = @__DIR__
features = `--enable-gc --enable-reference-types --enable-multivalue --enable-bulk-memory
            --enable-nontrapping-float-to-int --enable-sign-ext --enable-exception-handling
            --enable-tail-call --enable-mutable-globals`
run(`$(Binaryen_jll.wasmopt()) -O3 $features --closed-world --type-ssa --gufa
     $(joinpath(dir, "lorenz.wasm")) -o $(joinpath(dir, "lorenz.opt.wasm"))`)
bytes = read(joinpath(dir, "lorenz.opt.wasm"))

# the native time of the classic case, for reference
lorenz_solve(10.0, 28.0, 8 / 3, 1.0)
native = minimum(@elapsed(lorenz_solve(10.0, 28.0, 8 / 3, 1.0)) for _ in 1:20) * 1000

stats = Dict(split(l, "=") |> p -> p[1] => p[2] for l in readlines(joinpath(dir, "stats.txt")))
html = read(joinpath(dir, "page.template.html"), String)
html = replace(html, "__WASM_BASE64__" => base64encode(bytes),
               "__SIZE__" => string(round(Int, length(bytes) / 1024)),
               "__FUNCS__" => stats["functions"], "__OBJECTS__" => stats["objects"],
               "__NATIVE__" => string(round(native, digits=1)))
write(joinpath(dir, "lorenz.html"), html)
println("lorenz.html: $(length(html)) bytes (module $(length(bytes)) bytes), native $(round(native, digits=2)) ms")
