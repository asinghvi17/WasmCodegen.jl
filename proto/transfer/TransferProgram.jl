module TransferProgram

# Runtime definitions are loadable without the frontend or the setup-only package.
mutable struct Accumulator
    coefficient::Float64
    value::Float64
end

function setup(config)
    initial = 0.0
    if config.bad_initializer
        fixtures = normpath(joinpath(@__DIR__, "fixtures"))
        fixtures in LOAD_PATH || pushfirst!(LOAD_PATH, fixtures)
        @eval import StagedBuildOnlyBad
        # Use the setup-only package result in the returned runtime state.
        initial = Base.invokelatest(StagedBuildOnlyBad.CALLBACK[], 0.0)::Float64
    end
    if haskey(ENV, "PROGRAMBUILD_SETUP_LOG")
        open(ENV["PROGRAMBUILD_SETUP_LOG"], "a") do io
            println(io, "pid=", getpid(), " imaging=", ccall(:jl_generating_output, Cint, ()),
                " bad_loaded=", isdefined(@__MODULE__, :StagedBuildOnlyBad))
        end
    end
    Accumulator(Float64(exp(-BigFloat(config.rate))), initial)
end

reset(s::Accumulator) = (s.value = 0.0; nothing)
step(s::Accumulator, x::Float64)::Float64 = (s.value = s.coefficient * s.value + x)
value(s::Accumulator)::Float64 = s.value
function checked(s::Accumulator, x::Int32)::Int32
    x < 0 && throw(DomainError(x))
    x
end
clear(s::Accumulator)::Int32 = (reset(s); Int32(0))

function spec(; bad_initializer=true)
    P = Main.ProgramBuild
    P.ProgramSpec(name="transfer", setup=setup,
        config=(rate=log(2.0), bad_initializer=bad_initializer),
        instances=P.BakedPool(4), reset=reset,
        source=@__FILE__, exports=[
            P.ExportSpec(:step, step, (Float64,); returns=Float64),
            P.ExportSpec(:value, value, (); returns=Float64),
            P.ExportSpec(:checked, checked, (Int32,); returns=Int32),
            P.ExportSpec(:clear, clear, (); returns=Int32)])
end
end
