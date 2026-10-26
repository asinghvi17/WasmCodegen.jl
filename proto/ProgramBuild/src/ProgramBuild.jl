module ProgramBuild
import JSON
using Serialization
export BakedPool, ExportSpec, ProgramSpec, WasmGC, NativeLibrary,
       ImageLocal, Transferred, build, lower
struct WasmGC end
struct NativeLibrary end
struct ImageLocal end
struct Transferred end
identifier(x) = occursin(r"^[A-Za-z_][A-Za-z_0-9]*$", string(x))
const HOST_TYPES = (Int32, UInt32, Int64, UInt64, Float32, Float64)
const OK = Int32(0)
const INVALID_HANDLE = Int32(-1)
const POOL_FULL = Int32(-2)

"A fixed pool of independently constructed build-time states."
struct BakedPool
    capacity::Int
    function BakedPool(n::Integer)
        0 < n <= typemax(UInt32) || throw(ArgumentError("invalid pool capacity"))
        new(Int(n))
    end
end

struct ExportSpec
    name::Symbol
    f::Any
    argtypes::Tuple
    returns::DataType
    function ExportSpec(name, f, argtypes::Tuple; returns)
        name = Symbol(name)
        identifier(name) || throw(ArgumentError("invalid export name"))
        name in (:create, :destroy, :handle) && throw(ArgumentError("reserved API name"))
        all(T -> T in HOST_TYPES, (argtypes..., returns)) ||
            throw(ArgumentError("host signatures require fixed-width scalar types"))
        new(name, f, argtypes, returns)
    end
end

struct ProgramSpec
    name::String
    setup::Any
    config::Any
    exports::Vector{ExportSpec}
    instances::BakedPool
    reset::Any
    source::String
end

function ProgramSpec(; name, setup, config, exports, instances=BakedPool(1), reset, source)
    identifier(name) || throw(ArgumentError("invalid program name"))
    isfile(source) || throw(ArgumentError("missing runtime source"))
    es = ExportSpec[exports...]
    length(unique(e.name for e in es)) == length(es) ||
        throw(ArgumentError("duplicate export names"))
    isempty(es) && throw(ArgumentError("at least one operation is required"))
    return ProgramSpec(String(name), setup, config, es, instances, reset, abspath(source))
end


function functionref(f)
    m, n = parentmodule(f), nameof(f)
    Base.isidentifier(string(n)) && isdefined(m, n) && getglobal(m, n) === f ||
        throw(ArgumentError("use a named, module-level function"))
    parts = filter(!=(:Main), collect(Base.fullname(m)))
    join(string.([parts; n]), ".")
end
function literal(x)
    x === nothing && return "nothing"
    x isa Union{Bool, AbstractString, Symbol} && return repr(x)
    if typeof(x) in HOST_TYPES
        return "$(typeof(x))($(repr(x)))"
    elseif x isa NamedTuple
        return "(; " * join(["$k = $(literal(v))" for (k, v) in pairs(x)], ", ") * ")"
    elseif x isa Tuple
        return "(" * join(literal.(x), ", ") * (length(x) == 1 ? ",)" : ")")
    end
    throw(ArgumentError("config supports scalar host types, strings, symbols, tuples and named tuples"))
end


function validate_states(spec, states)
    length(states) == spec.instances.capacity || throw(ArgumentError("wrong state count"))
    S = typeof(first(states))
    isconcretetype(S) && all(s -> typeof(s) === S, states) ||
        throw(ArgumentError("setup must always return the same concrete state type"))
    applicable(spec.reset, first(states)) || throw(ArgumentError("missing reset!(::S)"))
    for e in spec.exports
        hasmethod(e.f, Tuple{S,e.argtypes...}) ||
            throw(ArgumentError("missing method for $(e.name)(::S, args...)"))
    end
    return Vector{S}(states)
end

"Source shared by both targets; only tuple-to-host adaptation differs."
function kernel_source(spec)
    sources = String[]
    define(source) = push!(sources, source)
    define("""
    @inline function lookup(h::UInt64)::Int
        slot = UInt32(h & UInt64(0xffffffff))
        generation = UInt32(h >> 32)
        (slot == 0 || slot > length(STATES) || generation == 0) && return 0
        i = Int(slot)
        (@inbounds ACTIVE[i] && GENERATIONS[i] == generation) || return 0
        return i
    end
    """)
    define("""
    function create()::Tuple{Int32,UInt64}
        for i in eachindex(STATES)
            if !(@inbounds ACTIVE[i]) && (@inbounds GENERATIONS[i]) != 0
                RESET(@inbounds STATES[i])
                @inbounds ACTIVE[i] = true
                h = (UInt64(@inbounds GENERATIONS[i]) << 32) | UInt64(i)
                return (Int32(0), h)
            end
        end
        return (Int32(-2), UInt64(0))
    end
    """)
    define("""
    function destroy(h::UInt64)::Tuple{Int32,Int32}
        i = lookup(h)
        i == 0 && return (Int32(-1), Int32(0))
        @inbounds begin
            ACTIVE[i] = false
            GENERATIONS[i] += UInt32(1)
        end
        return (Int32(0), Int32(0))
    end
    """)
    for (j, e) in enumerate(spec.exports)
        op = Symbol("OP_", j)
        wrapper = Symbol("export_", e.name)
        args = ["a$i::$(T)" for (i, T) in enumerate(e.argtypes)]
        params = join(["h::UInt64"; args], ", ")
        callargs = join(["(@inbounds STATES[i])"; ["a$i" for i in eachindex(args)]], ", ")
        define("""
        function $wrapper($params)::Tuple{Int32,$(e.returns)}
            i = lookup(h)
            i == 0 && return (Int32(-1), zero($(e.returns)))
            value = $op($callargs)::$(e.returns)
            return (Int32(0), value)
        end
        """)
    end
    return join(sources, "\n")
end

function logical_manifest(spec)
    exports = [(; name="create", args=String[], returns="UInt64"),
               (; name="destroy", args=["UInt64"], returns="Int32")]
    append!(exports, [(; name=string(e.name), args=string.([UInt64,e.argtypes...]),
                         returns=string(e.returns)) for e in spec.exports])
    (; schema_version=1, name=spec.name, capacity=spec.instances.capacity, exports,
       handle=(; type="UInt64", slot_bits=32, generation_bits=32,
                 invalid="0", scope="one artifact instance", generation_zero="retired"),
       statuses=(; ok=0, invalid_handle=-1, pool_full=-2, null_pointer=-3, exception=-4),
       concurrency="serialized host calls")
end

"Merge physical signatures while requiring the logical declaration to match."
function write_manifest(spec, section, output_dir)
    mkpath(output_dir)
    path = joinpath(output_dir, spec.name * ".json")
    logical = JSON.parse(JSON.json(logical_manifest(spec)))
    manifest = isfile(path) ? JSON.parsefile(path) : Dict("logical"=>logical,"targets"=>Dict())
    manifest["logical"] == logical || throw(ArgumentError("manifest logical spec mismatch"))
    # Target section is a dictionary or named tuple keyed by target name.
    merge!(manifest["targets"], JSON.parse(JSON.json(section)))
    write(path, JSON.json(manifest))
    path
end
include("wasm.jl")
include("transfer.jl")
include("native.jl")
end
