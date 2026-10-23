# Collecting the closed world of code an entry point can run, as juliac does
# (`Compiler.typeinf_ext_toplevel`): a compilation queue drained by `CC.compile!` under
# the Wasm interpreter, which yields the (CodeInstance, CodeInfo) pairs of every function
# to compile.

"""
    ClosedWorld

The functions to compile: for every method instance, its CodeInstance and its optimized
source, in the order they were collected, and the entry points.
"""
struct ClosedWorld
    world::UInt
    method_table::Core.MethodTable
    entries::Vector{Core.MethodInstance}
    order::Vector{Core.MethodInstance}
    sources::IdDict{Core.MethodInstance,Tuple{Core.CodeInstance,Core.CodeInfo}}
    "What the trim verifier reported (empty if verification was off or clean)."
    trim_report::Base.RefValue{String}
end

"""
    entry_instance(f, argtypes; world) -> MethodInstance

The method instance a call of `f` with arguments of types `argtypes` dispatches to.
"""
function entry_instance(@nospecialize(f), @nospecialize(argtypes::Tuple);
                        world::UInt=Base.get_world_counter(), method_table=WASM_MT)
    tt = Tuple{Core.Typeof(f),argtypes...}
    matches = CC.findall(tt, StackedMethodTable(world, method_table); limit=1)
    (matches === nothing || length(matches) != 1) &&
        error("no unique method for $tt")
    match = CC.getindex(matches, 1)::Core.MethodMatch
    return CC.specialize_method(match)
end

# `CC.compile!` takes whether code may link against code in images from Julia 1.13 on:
# the closed world does not
const COMPILE_KWARGS = VERSION >= v"1.13-" ? (; external_linkage=false) : (;)

"""
    collect_world(entries; world, verify=:warn) -> ClosedWorld

Infer the entry method instances and everything they call, as juliac does. Calls kept
as `:invoke`s of method instances inference did not keep source for (error paths) are
inferred too, to a fixpoint. With `verify` (`:error`, `:warn` or `:off`), the result is
checked with juliac's trim verifier, which reports dynamic dispatch.
"""
function collect_world(entries::Vector{Core.MethodInstance};
                       world::UInt=Base.get_world_counter(), verify::Symbol=:warn,
                       method_table=WASM_MT)
    w = ClosedWorld(world, method_table, entries, Core.MethodInstance[],
                    IdDict{Core.MethodInstance,Tuple{Core.CodeInstance,Core.CodeInfo}}(),
                    Ref(""))
    extend_world!(w, entries)
    if verify !== :off
        all = Any[]
        for mi in w.order
            ci, src = w.sources[mi]
            push!(all, ci, src)
        end
        io = IOBuffer()
        try
            CC.verify_typeinf_trim(io, all, verify === :warn)
        catch err
            err isa Core.TrimFailure || rethrow()
            error("the code of the entry points is not trim-safe:\n", String(take!(io)))
        end
        w.trim_report[] = String(take!(io))
    end
    return w
end

"""
    extend_world!(w, mis) -> ClosedWorld

Add the method instances `mis` and everything they call to the closed world `w` (the
code generator asks for the functions of its runtime this way).
"""
function extend_world!(w::ClosedWorld, mis::Vector{Core.MethodInstance})
    interp = WasmInterpreter(; world=w.world, method_table=w.method_table)
    codeinfos = Any[]
    wq = CC.CompilationQueue(; interp)
    ilq = CC.CompilationQueue(; interp)
    append!(wq, [mi for mi in mis if !haskey(w.sources, mi)])
    while true
        CC.compile!(codeinfos, wq; invokelatest_queue=ilq, COMPILE_KWARGS...)
        CC.compile!(codeinfos, ilq; invokelatest_queue=ilq, COMPILE_KWARGS...)
        for i in 1:2:length(codeinfos)
            ci, src = codeinfos[i], codeinfos[i+1]
            (ci isa Core.CodeInstance && src isa Core.CodeInfo) || continue
            mi = CC.get_ci_mi(ci)
            haskey(w.sources, mi) && continue
            w.sources[mi] = (ci, src)
            push!(w.order, mi)
        end
        # the targets of `:invoke`s that are not in the world yet
        missing = Core.MethodInstance[]
        for mi in w.order, stmt in w.sources[mi][2].code
            Meta.isexpr(stmt, :invoke) || continue
            target = stmt.args[1]
            tmi = target isa Core.CodeInstance ? CC.get_ci_mi(target) : target
            tmi isa Core.MethodInstance || continue
            haskey(w.sources, tmi) || tmi in missing || push!(missing, tmi)
        end
        isempty(missing) && break
        empty!(codeinfos)
        append!(wq, missing)
    end
    return w
end
