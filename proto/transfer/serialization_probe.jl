using Serialization
push!(LOAD_PATH, joinpath(@__DIR__, "../../.task/app-env"))

kind, action, bundle = ARGS
if action == "consume-without-source"
    deserialize(bundle)
    error("unexpected success without runtime definitions")
end
if kind == "build-only-type"
    if action == "produce"
        pushfirst!(LOAD_PATH, joinpath(@__DIR__, "fixtures"))
        @eval import SetupOnlyTypes
        serialize(bundle, SetupOnlyTypes.State(1.0))
        println("PASS serialize build-only package type")
    else
        deserialize(bundle) # expected failure: package absent from reader LOAD_PATH
        error("unexpected success with unavailable package type")
    end
elseif kind == "sciml"
    include(joinpath(@__DIR__, "../LorenzProgram.jl"))
    if action == "produce"
        states = [LorenzProgram.setup(LorenzProgram.CONFIG) for _ in 1:2]
        serialize(bundle, states)
        println("PASS serialize two concrete integrators: ", eltype(states))
    elseif action == "consume"
        states = deserialize(bundle)
        @assert isconcretetype(eltype(states))
        @assert length(states) == 2 && states[1] !== states[2]
        @assert states[1].u == states[2].u
        params = (10.0, 28.0, 8/3, 1.0)
        fresh = LorenzProgram.setup(LorenzProgram.CONFIG)
        n = LorenzProgram.solve!(states[1], params...)
        nfresh = LorenzProgram.solve!(fresh, params...)
        @assert n == nfresh
        for i in 1:n, k in 1:3
            @assert LorenzProgram.point(states[1],Int32(i),Int32(k)) == LorenzProgram.point(fresh,Int32(i),Int32(k))
        end
        @assert states[2].t == 0.0
        LorenzProgram.reset!(states[1])
        @assert states[1].t == 0.0 && states[1].u == states[2].u
        println("PASS deserialize/solve/reset/independence: ", n, " points identical to fresh setup")
    else
        error("unknown action")
    end
else
    include(joinpath(@__DIR__, "CallableGraphs.jl"))
    if action == "produce"
        f = kind == "named" ? CallableGraphs.named :
            kind == "closure" ? CallableGraphs.make_closure(2.0) :
            kind == "rgf" ? CallableGraphs.make_rgf() :
            kind == "rgf-dropped" ? CallableGraphs.make_rgf_dropped() : error("unknown callable kind")
        @assert f(3.0) == 5.0
        serialize(bundle, f)
        println("PASS serialize ", kind, ": ", typeof(f))
    elseif action == "consume"
        f = deserialize(bundle)
        @assert f(3.0) == 5.0
        println("PASS deserialize/call ", kind, ": ", typeof(f))
    else
        error("unknown action")
    end
end
