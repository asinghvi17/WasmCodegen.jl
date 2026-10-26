include(joinpath(@__DIR__, "../paths.jl"))
include(joinpath(@__DIR__, "../LorenzProgram.jl"))
const OUT = abspath(joinpath(@__DIR__, "../../.task/native-build/lorenz-transferred"))
mkpath(OUT)
parameters = [(10.0,28.0,8/3,1.0), (12.0,30.0,2.5,1.25)]
reference = map(parameters) do p
    s = LorenzProgram.setup(LorenzProgram.CONFIG)
    n = LorenzProgram.solve!(s,p...)
    [[LorenzProgram.point(s,Int32(i),Int32(k)) for k in 1:3] for i in 1:n]
end
write(joinpath(OUT,"reference.json"),ProgramBuild.JSON.json(reference))
product = build(LorenzProgram.spec(), NativeLibrary(); output_dir=OUT,
    project=joinpath(@__DIR__,"../../.task/app-env"), mode=Transferred())
println("LIBRARY=", product.library)
