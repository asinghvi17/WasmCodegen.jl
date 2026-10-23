# The abstract interpreter that infers code for Wasm: Julia's native inference, with its own
# code cache. There is no overlay method table: what Wasm needs replaced is replaced by
# method definitions in a newer world (`patches.jl`), as juliac does, so inference (and its
# concrete evaluation) is the native one.

"The owner of the CodeInstances inferred for Wasm in Julia's code cache."
struct WasmCacheOwner end

"""
    CodegenSources

The optimized sources of CodeInstances that `CC.compile!` reads (`interp.codegen`): those
stashed by inference, and, for CodeInstances of the Wasm cache inferred by an earlier
interpreter, their cached source, uncompressed on demand. (For an owner other than
native code, `CC.ci_has_source` accepts a cached CodeInstance by its `inferred` field
without putting its source here, which `CC.compile!` requires.)
"""
struct CodegenSources <: AbstractDict{Core.CodeInstance,Core.CodeInfo}
    dict::IdDict{Core.CodeInstance,Core.CodeInfo}
end
CodegenSources() = CodegenSources(IdDict{Core.CodeInstance,Core.CodeInfo}())

function cached_source(d::CodegenSources, ci::Core.CodeInstance)
    src = get(d.dict, ci, nothing)
    src === nothing || return src
    ci.owner === WasmCacheOwner() || return nothing
    inf = @atomic :monotonic ci.inferred
    inf isa String && (inf = CC._uncompressed_ir(ci, inf))
    inf isa Core.CodeInfo || return nothing
    d.dict[ci] = inf
    return inf
end

Base.get(d::CodegenSources, ci::Core.CodeInstance, default) =
    something(cached_source(d, ci), Some(default))
Base.haskey(d::CodegenSources, ci::Core.CodeInstance) = cached_source(d, ci) !== nothing
Base.getindex(d::CodegenSources, ci::Core.CodeInstance) =
    something(cached_source(d, ci), Some(nothing))::Core.CodeInfo
Base.setindex!(d::CodegenSources, src::Core.CodeInfo, ci::Core.CodeInstance) = (d.dict[ci] = src; d)
Base.length(d::CodegenSources) = length(d.dict)
Base.iterate(d::CodegenSources, s...) = iterate(d.dict, s...)

"""
    WasmInterpreter(; world)

Julia's native inference and optimization in `world`, with its own code cache.
"""
struct WasmInterpreter <: CC.AbstractInterpreter
    world::UInt
    method_table::CC.CachedMethodTable{CC.InternalMethodTable}
    inf_cache::Vector{CC.InferenceResult}
    inf_params::CC.InferenceParams
    opt_params::CC.OptimizationParams
    "The uncompressed source of the CodeInstances inferred, for `CC.compile!`."
    codegen::CodegenSources
end

function WasmInterpreter(; world::UInt=Base.get_world_counter())
    mt = CC.CachedMethodTable(CC.InternalMethodTable(world))
    inf_params = CC.InferenceParams(; force_enable_inference=true)
    opt_params = CC.OptimizationParams()
    return WasmInterpreter(world, mt, CC.InferenceResult[], inf_params, opt_params,
                           CodegenSources())
end

CC.InferenceParams(interp::WasmInterpreter) = interp.inf_params
CC.OptimizationParams(interp::WasmInterpreter) = interp.opt_params
CC.get_inference_world(interp::WasmInterpreter) = interp.world
CC.get_inference_cache(interp::WasmInterpreter) = interp.inf_cache
CC.method_table(interp::WasmInterpreter) = interp.method_table
CC.cache_owner(::WasmInterpreter) = WasmCacheOwner()
CC.codegen_cache(interp::WasmInterpreter) = interp.codegen
CC.may_discard_trees(::WasmInterpreter) = false

# `have_fma` is false on Wasm (no fused multiply-add): fold it, so that math code picks
# its kernel without fma at compile time
function fold_target_intrinsic(@nospecialize(f), argtypes::Vector{Any})
    f === Core.Intrinsics.have_fma || return nothing
    return CC.CallMeta(CC.Const(false), Union{}, CC.EFFECTS_TOTAL, CC.NoCallInfo())
end

function CC.abstract_call_known(interp::WasmInterpreter, @nospecialize(f),
                                arginfo::CC.ArgInfo, si::CC.StmtInfo, sv::CC.InferenceState,
                                max_methods::Int=CC.get_max_methods(interp, f, sv))
    folded = fold_target_intrinsic(f, arginfo.argtypes)
    folded === nothing || return CC.Future{CC.CallMeta}(folded)
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any,
                                          arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          sv::CC.InferenceState, max_methods::Int)
end
