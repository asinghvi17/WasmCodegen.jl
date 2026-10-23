# Build the page: julia +1.13 --project=. page.jl (after build.jl), writing parser.html with
# the module embedded
using Base64

dir = @__DIR__
bytes = read(joinpath(dir, "parser.wasm"))   # optimized by `compile` (wasm-opt -O3)

stats = Dict(split(l, "=") |> p -> p[1] => p[2] for l in readlines(joinpath(dir, "stats.txt")))
html = read(joinpath(dir, "page.template.html"), String)
html = replace(html, "__WASM_BASE64__" => base64encode(bytes),
               "__SIZE__" => string(round(Int, length(bytes) / 1024)),
               "__FUNCS__" => stats["functions"], "__OBJECTS__" => stats["objects"])
write(joinpath(dir, "parser.html"), html)
println("parser.html: $(length(html)) bytes (module $(length(bytes)) bytes)")
