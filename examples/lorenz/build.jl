# Build lorenz.wasm from model.jl: julia --project=<env with the model's packages> build.jl
using WasmCodegen
include("model.jl")

c = WasmCodegen.with_trim_patches() do _, _
    WasmCodegen.compile([WasmCodegen.Entry(f, at) for (f, at) in ENTRIES])
end
write(joinpath(@__DIR__, "lorenz.wasm"), c.bytes)
println("lorenz.wasm: $(length(c.bytes)) bytes, $(length(c.cgm.funcs)) functions, ",
        "$(length(c.cgm.image.globals)) serialized objects")
write(joinpath(@__DIR__, "stats.txt"),
      "functions=$(length(c.cgm.funcs))\nobjects=$(length(c.cgm.image.globals))\n")
