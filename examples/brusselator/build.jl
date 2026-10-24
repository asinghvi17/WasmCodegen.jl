# Build brusselator.wasm from model.jl: julia +1.13 --project=. build.jl
using WasmCodegen
include("model.jl")

t = @elapsed c = WasmCodegen.with_trim_patches() do _, _
    WasmCodegen.compile([WasmCodegen.Entry(f, at) for (f, at) in ENTRIES])
end
write(joinpath(@__DIR__, "brusselator.wasm"), c.bytes)
println("brusselator.wasm: $(length(c.bytes)) bytes, $(length(c.cgm.funcs)) functions, ",
        "exceptions $(c.cgm.exceptions), $(length(c.cgm.image.globals)) serialized objects, ",
        "compiled in $(round(t, digits=1)) s")
write(joinpath(@__DIR__, "stats.txt"),
      "functions=$(length(c.cgm.funcs))\nobjects=$(length(c.cgm.image.globals))\n")
