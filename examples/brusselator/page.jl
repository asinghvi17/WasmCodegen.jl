# Build the demo page: julia +1.13 --project=. page.jl (after build.jl)
using Base64
include("model.jl")

dir = @__DIR__
bytes = read(joinpath(dir, "brusselator.wasm"))   # optimized by `compile` (wasm-opt -O3)

# native times of the default case, for reference
native = map(Int32(1):Int32(3)) do k
    bz_solve(k, 1.0, 3.0, 0.02, 1.0)
    round(minimum(@elapsed(bz_solve(k, 1.0, 3.0, 0.02, 1.0)) for _ in 1:20) * 1000, digits=2)
end

stats = Dict(split(l, "=") |> p -> p[1] => p[2] for l in readlines(joinpath(dir, "stats.txt")))
html = read(joinpath(dir, "page.template.html"), String)
host = read(normpath(joinpath(dir, "..", "..", "js", "julia.mjs")))
html = replace(html, "__WASM_BASE64__" => base64encode(bytes),
               "__JULIA_HOST__" => "data:text/javascript;base64," * base64encode(host),
               "__SIZE__" => string(round(Int, length(bytes) / 1024)),
               "__FUNCS__" => stats["functions"], "__OBJECTS__" => stats["objects"],
               "__NATIVE__" => join(native, ","), "__N__" => string(N))
write(joinpath(dir, "brusselator.html"), html)
println("brusselator.html: $(length(html)) bytes (module $(length(bytes)) bytes), native ms $(native)")
