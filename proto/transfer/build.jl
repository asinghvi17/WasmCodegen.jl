include(joinpath(@__DIR__, "../ProgramBuild/src/ProgramBuild.jl"))
include(joinpath(@__DIR__, "TransferProgram.jl"))
using .ProgramBuild

variant = only(ARGS)
variant in ("baseline", "image-local-bad", "transferred-bad") || error("unknown variant")
output_dir = abspath(joinpath(@__DIR__, "../../.task/native-build", variant))
mkpath(output_dir)
ENV["PROGRAMBUILD_SETUP_LOG"] = joinpath(output_dir, "setup.log")
write(ENV["PROGRAMBUILD_SETUP_LOG"], "")
mode = variant == "transferred-bad" ? Transferred() : ImageLocal()
product = build(TransferProgram.spec(bad_initializer=variant != "baseline"), NativeLibrary();
    output_dir, mode, project=joinpath(@__DIR__, "../../.task/app-env"))
println("LIBRARY=", product.library)
