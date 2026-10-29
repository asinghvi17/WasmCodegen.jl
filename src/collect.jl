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
                        world::UInt=Base.get_world_counter())
    tt = Tuple{Core.Typeof(f),argtypes...}
    matches = CC.findall(tt, CC.InternalMethodTable(world); limit=1)
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
                       world::UInt=Base.get_world_counter(), verify::Symbol=:warn)
    w = ClosedWorld(world, entries, Core.MethodInstance[],
                    IdDict{Core.MethodInstance,Tuple{Core.CodeInstance,Core.CodeInfo}}(),
                    Ref(""))
    verify === :off || (w.trim_report[] = trim_check(entries; world, onlywarn=verify === :warn))
    extend_world!(w, entries)
    return w
end

"""
    TrimFailure

The entry points are not trim-safe: juliac's verifier found dynamic dispatch (or other
constructs that need the Julia runtime) in the code they run.
"""
struct TrimFailure <: Exception
    report::String
end
Base.showerror(io::IO, e::TrimFailure) =
    print(io, "the code of the entry points is not trim-safe (as juliac --trim=safe checks):\n", e.report)

# the rounds of inferring invoke targets as entries in `trim_check`
const MAX_INVOKE_ROUNDS = 8

"""
    trim_check(entries; world, onlywarn=false) -> String

Check the entry points as `juliac --trim=safe` does: native inference collects the code
they run (`Compiler.typeinf_ext_toplevel`), and juliac's verifier checks it. Returns the
verifier's report, and throws a [`TrimFailure`](@ref) if it found errors (unless
`onlywarn`). This is the subset of Julia the code generator targets.

An `:invoke` of a method instance without a code instance (one inferred only as part of a
recursion cycle, or whose cached code the patches invalidated) is a static call, which the
code generator compiles, but the verifier rejects it as unresolved: native inference does
not compile its target. Each such target is inferred as an entry of its own, and the invoke
made of its code instance; the verifier checks that code as any other. (For a few rounds: the
targets of a program whose specializations do not end, as recursive invokes of ever deeper
types, stay unresolved invokes.)
"""
function trim_check(entries::Vector{Core.MethodInstance}; world::UInt=Base.get_world_counter(),
                    onlywarn::Bool=false)
    args = VERSION >= v"1.13-" ? (CC.TRIM_UNSAFE, false) : (CC.TRIM_UNSAFE,)
    roots = Any[entries...]
    codeinfos = CC.typeinf_ext_toplevel(copy(roots), UInt[world], args...)
    for _ in 1:MAX_INVOKE_ROUNDS
        targets = filter(mi -> !(mi in roots), uncompiled_invoke_targets(codeinfos))
        isempty(targets) && break
        append!(roots, targets)
        codeinfos = CC.typeinf_ext_toplevel(copy(roots), UInt[world], args...)
    end
    link_invoke_targets!(codeinfos)
    io = IOBuffer()
    try
        redirect_stdout(devnull) do
            CC.verify_typeinf_trim(io, codeinfos, onlywarn)
        end
    catch err
        err isa Core.TrimFailure || rethrow()
        throw(TrimFailure(String(take!(io))))
    end
    return String(take!(io))
end

# the code instances of `codeinfos` the verifier links invokes to, by method instance: native
# ones valid in the current world, of the instance itself (`get_verify_typeinf_trim`'s)
function linkable_code(codeinfos::Vector{Any})
    now = Base.get_world_counter()
    code = IdDict{Core.MethodInstance,Core.CodeInstance}()
    for item in codeinfos
        item isa Core.CodeInstance && item.owner === nothing && item.min_world <= now <= item.max_world &&
            CC.get_ci_mi(item) === item.def && (code[item.def] = item)
    end
    return code
end

# the statement's invoke target when it is a bare method instance (else nothing)
function invoked_instance(@nospecialize(st))
    ex = Meta.isexpr(st, :(=)) ? st.args[2] : st
    Meta.isexpr(ex, :invoke) && ex.args[1] isa Core.MethodInstance || return nothing
    return ex.args[1]::Core.MethodInstance
end

# the method instances `codeinfos` invoke without a code instance of them in `codeinfos`
function uncompiled_invoke_targets(codeinfos::Vector{Any})
    code = linkable_code(codeinfos)
    targets = Core.MethodInstance[]
    for i in 1:length(codeinfos)
        codeinfos[i] isa Core.CodeInstance || continue
        for st in (codeinfos[i + 1]::Core.CodeInfo).code
            mi = invoked_instance(st)
            mi === nothing || haskey(code, mi) || mi in targets || push!(targets, mi)
        end
    end
    return targets
end

# the invokes of a bare method instance with a code instance in `codeinfos`, of that code
# instance (in copies of the sources: they are inference's)
function link_invoke_targets!(codeinfos::Vector{Any})
    code = linkable_code(codeinfos)
    for i in 1:length(codeinfos)
        codeinfos[i] isa Core.CodeInstance || continue
        src = codeinfos[i + 1]::Core.CodeInfo
        any(st -> (mi = invoked_instance(st); mi !== nothing && haskey(code, mi)), src.code) || continue
        src = copy(src)
        src.code = copy(src.code)
        for j in eachindex(src.code)
            st = src.code[j]
            mi = invoked_instance(st)
            (mi !== nothing && haskey(code, mi)) || continue
            ex = Meta.isexpr(st, :(=)) ? st.args[2] : st
            linked = Expr(:invoke, code[mi], ex.args[2:end]...)
            src.code[j] = Meta.isexpr(st, :(=)) ? Expr(:(=), st.args[1], linked) : linked
        end
        codeinfos[i + 1] = src
    end
    return codeinfos
end

"""
    extend_world!(w, mis) -> ClosedWorld

Add the method instances `mis` and everything they call to the closed world `w` (the
code generator asks for the functions of its runtime this way).
"""
function extend_world!(w::ClosedWorld, mis::Vector{Core.MethodInstance})
    interp = WasmInterpreter(; world=w.world)
    codeinfos = Any[]
    wq = CC.CompilationQueue(; interp)
    ilq = CC.CompilationQueue(; interp)
    initial = [mi for mi in mis if !haskey(w.sources, mi)]
    append!(wq, initial)
    # Each method instance is asked for once: one that comes back without a source would
    # otherwise be missing, and asked for, again on every round, without end. Each round scans
    # only the functions it added. A target left without a source is not in the world: a call
    # to it that survives to emission is an unsupported construct there (get_function!).
    requested = Base.IdSet{Core.MethodInstance}(initial)
    scanned = length(w.order)
    trace = get(ENV, "WCG_COLLECT_TRACE", "") == "1"
    nround = 0
    t0 = time()
    while true
        nround += 1
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
        # the targets of `:invoke`s in the functions this round added that are not in the
        # world yet and were not asked for before
        missing = Core.MethodInstance[]
        for k in scanned+1:length(w.order), stmt in w.sources[w.order[k]][2].code
            Meta.isexpr(stmt, :invoke) || continue
            target = stmt.args[1]
            tmi = target isa Core.CodeInstance ? CC.get_ci_mi(target) : target
            tmi isa Core.MethodInstance || continue
            haskey(w.sources, tmi) || tmi in requested || (push!(requested, tmi); push!(missing, tmi))
        end
        trace && println(stderr, "extend_world! round ", nround, ": world ", length(w.order), " (+",
                         length(w.order) - scanned, "), new :invoke targets ", length(missing), ", ",
                         round(time() - t0; digits = 1), " s")
        trace && flush(stderr)
        scanned = length(w.order)
        isempty(missing) && break
        empty!(codeinfos)
        append!(wq, missing)
    end
    # asked for, but inference kept no source for them
    unresolved = [mi for mi in requested if !haskey(w.sources, mi)]
    if trace && !isempty(unresolved)
        println(stderr, "extend_world!: ", length(unresolved), " :invoke targets without a source, e.g. ",
                join((sprint(show, mi; context = :limit => true) for mi in first(unresolved, 5)), "; "))
        flush(stderr)
    end
    return w
end
