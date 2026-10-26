include("paths.jl")
include("LorenzProgram.jl")
using JSON
const OUT = joinpath(@__DIR__, "build", "lorenz")
mkpath(OUT)
const PARAMETERS = [(10.0,28.0,8/3,1.0), (12.0,30.0,2.5,1.25)]
if isempty(ARGS) || "reference" in ARGS
    reference = map(PARAMETERS) do p
        s = LorenzProgram.setup(LorenzProgram.CONFIG)
        n = LorenzProgram.solve!(s,p...)
        (; parameters=p, count=n, points=[[LorenzProgram.point(s,Int32(i),Int32(k))
            for k in 1:3] for i in 1:n])
    end
    write(joinpath(OUT,"julia.json"),JSON.json(reference))
end
spec = LorenzProgram.spec()
if isempty(ARGS) || "wasm" in ARGS
    build(spec, WasmGC(); output_dir=OUT)
end
if isempty(ARGS) || "native" in ARGS
    build(spec, NativeLibrary(); output_dir=OUT,
          project=joinpath(@__DIR__,"..",".task","app-env"))
end
if "transferred" in ARGS
    build(spec, NativeLibrary(); output_dir=joinpath(@__DIR__,"build","lorenz-transfer"),
          project=joinpath(@__DIR__,"..",".task","app-env"), mode=Transferred())
end
