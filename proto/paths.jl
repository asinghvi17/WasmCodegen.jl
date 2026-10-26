# Builder dependencies are kept out of the generated runtime image source.
push!(LOAD_PATH, joinpath(@__DIR__, "..", ".task", "native-env"))
push!(LOAD_PATH, joinpath(@__DIR__, "..", ".task", "app-env"))
push!(LOAD_PATH, joinpath(@__DIR__, ".."))
include("ProgramBuild/src/ProgramBuild.jl")
using .ProgramBuild
