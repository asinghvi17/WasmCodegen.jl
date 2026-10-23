# The runtime: functions written in Julia that the code generator calls for what Wasm
# lacks (an exact fused multiply-add, ...). They are compiled into the module on demand,
# like the functions of libjulia native code calls.
#
# There are no overlays of Base's methods: inference is Julia's own (but for target facts
# like `have_fma`), so the code compiled is the code juliac compiles. What Base does with
# pointers and calls into the C runtime is compiled from the IR instead (`foreigncall.jl`,
# pointers with origins).

"""
    runtime_function!(cgm, f, argtypes) -> FuncInfo

The function compiled for the call `f(::argtypes...)`, which the code generator uses as
part of its runtime; it (and what it calls) is added to the closed world.
"""
function runtime_function!(cgm::CGModule, @nospecialize(f), @nospecialize(argtypes::Tuple))
    w = cgm.world
    mi = entry_instance(f, argtypes; world=w.world, method_table=w.method_table)
    haskey(w.sources, mi) || extend_world!(w, Core.MethodInstance[mi])
    return get_function!(cgm, mi)
end

"Call the runtime function `f(args...)`."
function call_runtime!(fc::FnCtx, @nospecialize(f), args::Vector{CGVal})
    info = runtime_function!(fc.cgm, f, Tuple(a.typ for a in args))
    return emit_call_info!(fc, info, CGVal[ghost(typeof(f), f), args...])
end

"""
    emit_intrinsic_call!(fc, mi, ex, typ) -> Union{Nothing,CGVal}

The code of an `:invoke` the code generator compiles itself, or `nothing` for other
calls. (None for now: kept as the hook for intrinsics of the runtime.)
"""
emit_intrinsic_call!(fc::FnCtx, mi::Core.MethodInstance, ex::Expr, @nospecialize(typ)) = nothing
