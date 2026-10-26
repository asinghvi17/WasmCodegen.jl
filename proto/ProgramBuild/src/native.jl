const NATIVE_JULIA_TYPES = (Int8, UInt8, Int16, UInt16, Int32, UInt32, Int64, UInt64, Float32, Float64)
const NATIVE_C_TYPES = ("int8_t", "uint8_t", "int16_t", "uint16_t", "int32_t", "uint32_t", "int64_t", "uint64_t", "float", "double")
function native_ctype(t)
    i = findfirst(==(t), NATIVE_JULIA_TYPES)
    i === nothing && throw(ArgumentError("unsupported native scalar: $t"))
    NATIVE_C_TYPES[i]
end

function native_signatures(spec)
    prefix = spec.name
    sigs = Any[
        (; name="$(prefix)_create", signature="int32_t $(prefix)_create(uint64_t *out)",
           result="status", out="uint64_t handle; written only on success"),
        (; name="$(prefix)_destroy", signature="int32_t $(prefix)_destroy(uint64_t h)",
           result="status", out=nothing)]
    for e in spec.exports
        args = ["uint64_t h"; ["$(native_ctype(t)) a$i" for (i,t) in enumerate(e.argtypes)]]
        e.returns === Nothing || push!(args, "$(native_ctype(e.returns)) *out")
        push!(sigs, (; name="$(prefix)_$(e.name)",
            signature="int32_t $(prefix)_$(e.name)(" * join(args, ", ") * ")",
            result="status", out=e.returns === Nothing ? nothing : "$(native_ctype(e.returns)); written only on success"))
    end
    sigs
end

function native_header(spec, path)
    guard = uppercase(spec.name) * "_PROGRAM_H"
    open(path, "w") do io
        println(io, "#ifndef $guard\n#define $guard\n#include <stdint.h>")
        println(io, "#ifdef __cplusplus\nextern \"C\" {\n#endif")
        println(io, "/* Single host thread. Julia entrypoints initialize the runtime.")
        println(io, " * Out pointers must be aligned/writable; null pointers are checked.")
        println(io, " * Outputs remain unchanged on failure. Exceptions may mutate state.")
        println(io, " * Handle = generation << 32 | one-based slot; zero is invalid. */")
        p = spec.name
        println(io, "enum { $(p)_OK=0, $(p)_INVALID=-1, $(p)_EXHAUSTED=-2, $(p)_NULL=-3, $(p)_EXCEPTION=-4 };")
        for sig in native_signatures(spec)
            println(io, sig.signature, ";")
        end
        println(io, "#ifdef __cplusplus\n}\n#endif\n#endif")
    end
    path
end

function native_adapter_source(spec)
    io = IOBuffer()
    p = spec.name
    println(io, "Base.@ccallable function $(p)_create(out::Ptr{UInt64})::Int32")
    println(io, "    out == C_NULL && return Int32(-3)\n    try")
    println(io, "        status, value = create()\n        status == 0 && unsafe_store!(out, value)\n        return status")
    println(io, "    catch\n        return Int32(-4)\n    end\nend")
    println(io, "Base.@ccallable function $(p)_destroy(h::UInt64)::Int32")
    println(io, "    try\n        status, _ = destroy(h)\n        return status\n    catch\n        return Int32(-4)\n    end\nend")
    for e in spec.exports
        args = ["h::UInt64"; ["a$i::$t" for (i,t) in enumerate(e.argtypes)]]
        hasout = e.returns !== Nothing
        hasout && push!(args, "out::Ptr{$(e.returns)}")
        println(io, "Base.@ccallable function $(p)_$(e.name)(", join(args, ", "), ")::Int32")
        hasout && println(io, "    out == C_NULL && return Int32(-3)")
        callargs = join(["h"; ["a$i" for i in eachindex(e.argtypes)]], ", ")
        println(io, "    try\n        status, value = export_$(e.name)($callargs)")
        hasout && println(io, "        status == 0 && unsafe_store!(out, value)")
        println(io, "        return status\n    catch\n        return Int32(-4)\n    end\nend")
    end
    String(take!(io))
end

function native_source(spec; bundle=nothing)
    io = IOBuffer()
    println(io, "# Generated runtime image source. Does not load ProgramBuild or JuliaC.")
    bundle === nothing || println(io, "using Serialization")
    println(io, "include(", repr(abspath(spec.source)), ")")
    println(io, "module ProgramBuildNative_", spec.name)
    if bundle === nothing
        println(io, "const STATES = let config = ", literal(spec.config))
        println(io, "    first = Main.$(functionref(spec.setup))(config)")
        println(io, "    states = Vector{typeof(first)}(undef, $(spec.instances.capacity))\n    states[1] = first")
        println(io, "    for i in 2:$(spec.instances.capacity)")
        println(io, "        state = Main.$(functionref(spec.setup))(config)")
        println(io, "        typeof(state) === typeof(first) || error(\"setup states must have the same concrete type\")")
        println(io, "        states[i] = state\n    end\n    states\nend")
    else
        println(io, "const STATES = Main.Serialization.deserialize(", repr(abspath(bundle)), ")")
    end
    println(io, "const STATE = eltype(STATES)")
    println(io, "isconcretetype(STATE) || error(\"setup state must have a concrete type\")")
    println(io, "length(STATES) == $(spec.instances.capacity) || error(\"state capacity mismatch\")")
    println(io, "all(s -> typeof(s) === STATE, STATES) || error(\"setup states must have the same concrete type\")")
    println(io, "const ACTIVE = fill(false, $(spec.instances.capacity))")
    println(io, "const GENERATIONS = fill(UInt32(1), $(spec.instances.capacity))")
    println(io, "const RESET = Main.", functionref(spec.reset))
    println(io, "applicable(RESET, first(STATES)) || error(\"missing reset method\")")
    for (j,e) in enumerate(spec.exports)
        println(io, "const OP_$j = Main.", functionref(e.f))
        ts = join(["STATE"; string.(collect(e.argtypes))], ", ")
        println(io, "hasmethod(OP_$j, Tuple{$ts}) || error(\"missing export method: $(e.name)\")")
    end
    println(io, kernel_source(spec))
    println(io, native_adapter_source(spec))
    println(io, "end\nGC.gc(true)")
    String(take!(io))
end

"""Compile a status/out-pointer C library with setup in the image or a producer."""
function build(spec::ProgramSpec, ::NativeLibrary; output_dir, project, mode=ImageLocal(),
               trim_mode="safe", bundle=false)
    mode isa Union{ImageLocal,Transferred} || throw(ArgumentError("unsupported native setup mode"))
    dir = abspath(output_dir)
    mkpath(dir)
    transfer = mode isa Transferred ? transferred_states(spec; output_dir=dir, project) : nothing
    source = joinpath(dir, "build.jl")
    write(source, native_source(spec; bundle=transfer === nothing ? nothing : transfer.bundle))
    header = native_header(spec, joinpath(dir, "program.h"))
    target = (; kind="native", setup_mode=mode isa Transferred ? "transferred" : "image_local",
        status_type="int32_t", success=0,
        statuses=Dict("invalid"=>-1, "exhausted"=>-2, "null"=>-3, "exception"=>-4),
        signatures=native_signatures(spec), threading="single host thread",
        out_pointers="required nonnull aligned writable pointers; unchanged on failure")
    manifest = write_manifest(spec, (; native=target), dir)
    @eval import JuliaC
    Base.invokelatest() do
        image = JuliaC.ImageRecipe(file=source, output_type="--output-lib",
            project=abspath(project), trim_mode=trim_mode, add_ccallables=true,
            cpu_target="native", export_abi=joinpath(dir,"abi.json"),
            img_path=joinpath(dir,"image.o.a"))
        JuliaC.compile_products(image)
        link = JuliaC.LinkRecipe(image_recipe=image, outname=joinpath(dir,"lib$(spec.name)"))
        JuliaC.link_products(link)
        if bundle
            JuliaC.bundle_products(JuliaC.BundleRecipe(link_recipe=link, output_dir=joinpath(dir,"bundle")))
        end
        (; library=link.outname, build_source=source, header, manifest, dir,
           setup_mode=target.setup_mode, transfer_bundle=transfer === nothing ? nothing : transfer.bundle)
    end
end
