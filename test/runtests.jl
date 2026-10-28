include("harness.jl")
include("juliac/programs.jl")
# programs inferred into a package image; precompiled before the patches, which change how
# Base prints the code it sends to the precompiling process
push!(LOAD_PATH, joinpath(@__DIR__, "PrecompiledPrograms"))
using PrecompiledPrograms
pop!(LOAD_PATH)

# one session of juliac's trim patches for all the tests (as juliac builds in one process)
WasmCodegen.with_trim_patches() do _, _
    include("basics.jl")
    include("data.jl")
    include("random.jl")
    include("dicts.jl")
    include("globals.jl")
    include("exceptions.jl")
    include("coverage.jl")
    include("linalg.jl")
    include("eachindex_trim.jl")
    include("regressions.jl")
    include("juliac/runtests.jl")
end
