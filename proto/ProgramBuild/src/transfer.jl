# The producer is deliberately an ordinary Julia subprocess. It never imports
# this frontend or JuliaC; its only inputs are the runtime source and setup call.
function transferred_states(spec::ProgramSpec; output_dir, project)
    dir = abspath(output_dir)
    mkpath(dir)
    bundle = joinpath(dir, "states.jls")
    producer = joinpath(dir, "producer.jl")
    log = joinpath(dir, "producer.log")
    setup_ref = functionref(spec.setup)
    source = abspath(spec.source)
    write(producer, """
    using Serialization
    include($(repr(source)))
    states = let config = $(literal(spec.config))
        first = Main.$setup_ref(config)
        states = Vector{typeof(first)}(undef, $(spec.instances.capacity))
        states[1] = first
        for i in 2:$(spec.instances.capacity)
            state = Main.$setup_ref(config)
            typeof(state) === typeof(first) || error("setup states must have the same concrete type")
            states[i] = state
        end
        states
    end
    Serialization.serialize($(repr(bundle)), states)
    println("serialized ", length(states), " states of ", eltype(states))
    """)
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(abspath(project)) $producer`
    open(log, "w") do io
        run(pipeline(cmd; stdout=io, stderr=io))
    end
    # The caller already loaded spec.source to obtain the spec. Consequently the
    # concrete runtime types and named functions are available for reconstruction.
    @eval import Serialization
    states = Base.invokelatest(Serialization.deserialize, bundle)
    states = validate_states(spec, states)
    (; bundle, producer, producer_log=log, states)
end
