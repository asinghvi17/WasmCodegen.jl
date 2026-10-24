# Preparing the IR of a function for structurizing and code generation.

"""
    get_ircode(world, mi) -> IRCode

The optimized IR of the method instance `mi` of the closed world.
"""
function get_ircode(w::ClosedWorld, mi::Core.MethodInstance)
    _, src = w.sources[mi]
    return CC.inflate_ir(src, mi)
end

"""
    strip_exception_handling!(ir) -> IRCode

Remove the exception handlers of `ir`, for code generation where `throw` traps: an
`EnterNode`'s edge to its handler is deleted (so handlers become unreachable and
compaction drops them), and `:leave`, `:pop_exception` and `UpsilonNode`s, which only
matter when a handler runs, are removed.

This changes the meaning of programs that catch exceptions: the exception terminates the
program (traps) instead. It is the policy of the first version of the code generator.
"""
function strip_exception_handling!(ir::CC.IRCode)
    stmts = ir.stmts
    changed = false
    for idx in 1:length(stmts)
        stmt = stmts[idx][:stmt]
        if stmt isa Core.EnterNode
            if stmt.catch_dest != 0
                bb = CC.block_for_inst(ir.cfg, idx)
                stmt.catch_dest in ir.cfg.blocks[bb].succs &&
                    CC.kill_edge!(ir, bb, stmt.catch_dest)
            end
            stmts[idx][:stmt] = nothing
            stmts[idx][:type] = Nothing
            changed = true
        elseif stmt isa Core.UpsilonNode ||
               Meta.isexpr(stmt, :leave) || Meta.isexpr(stmt, :pop_exception)
            stmts[idx][:stmt] = nothing
            stmts[idx][:type] = Nothing
            changed = true
        end
    end
    changed || return ir
    return CC.compact!(ir, true)
end

"""
    trap_throws!(ir) -> IRCode

Where the exception a `throw` throws is never observed (nothing catches, or nothing reads
what it catches), `throw(x)` becomes `throw(nothing)`, and the computations of values used
only to be thrown are removed when they have no effects and cannot throw (a computation
that may throw, as a division, stays: its exception happens before what follows it), or
when they are Base's own construction of an exception or its message (`print_to_string`
of the arguments of an error: effects on the buffer it allocates, which inference cannot
prove effect-free). Error paths then do not compile the code that formats error messages.
Calls of the program's functions stay even when they build exceptions, and calls of
functions that never return: their effects before they throw still happen.
"""
function trap_throws!(ir::CC.IRCode)
    stmts = ir.stmts
    n = length(stmts)
    nuses = zeros(Int, n)
    for idx in 1:n
        for ur in CC.userefs(stmts[idx][:stmt])
            v = ur[]
            v isa Core.SSAValue && (nuses[v.id] += 1)
        end
    end
    work = Int[]
    release!(stmt) = for ur in CC.userefs(stmt)
        v = ur[]
        if v isa Core.SSAValue
            nuses[v.id] -= 1
            nuses[v.id] == 0 && push!(work, v.id)
        end
    end
    for idx in 1:n
        stmt = stmts[idx][:stmt]
        stmt isa Expr && is_throw_call(stmt) && length(stmt.args) >= 2 || continue
        length(stmt.args) == 2 && stmt.args[2] === nothing && continue
        release!(stmt)
        stmts[idx][:stmt] = Expr(:call, GlobalRef(Core, :throw), nothing)
    end
    while !isempty(work)
        id = pop!(work)
        stmt = stmts[id][:stmt]
        stmt isa Expr && stmt.head in (:call, :invoke, :new, :foreigncall, :splatnew) || continue
        flag = stmts[id][:flag]
        nothrow = (flag & CC.IR_FLAG_NOTHROW) != 0
        removable = (nothrow && ((flag & CC.IR_FLAG_EFFECT_FREE) != 0 || is_pure_builtin_call(stmt))) ||
                    stmt.head === :new || stmt.head === :splatnew || is_pure_foreigncall(stmt) ||
                    is_base_message(stmt, stmts[id][:type])
        removable || continue
        release!(stmt)
        stmts[id][:stmt] = nothing
        stmts[id][:type] = Nothing
    end
    return ir
end

# a call of a method of Base or Core building an exception or the message of one
function is_base_message(stmt::Expr, @nospecialize(typ))
    stmt.head === :invoke || return false
    CC.widenconst(typ) <: Union{Exception,AbstractString,Symbol} || return false
    target = stmt.args[1]
    mi = target isa Core.CodeInstance ? CC.get_ci_mi(target) : target
    mi isa Core.MethodInstance && mi.def isa Method || return false
    root = Base.moduleroot(mi.def.module)
    return root === Base || root === Core
end

# builtins without effects on existing objects (they may allocate)
const PURE_BUILTINS = Any[Core.tuple, Core.getfield, Core._apply_iterate, Core.typeof,
                          Core.isa, Core.:(===), Core.memorynew, Core.memoryrefnew,
                          Core.memoryrefget, Core.nfields, Core.svec, Core.apply_type]

function is_pure_builtin_call(stmt::Expr)
    stmt.head === :call || return false
    f = stmt.args[1]
    f isa GlobalRef && isdefined(f.mod, f.name) && isconst(f.mod, f.name) && (f = getglobal(f.mod, f.name))
    return f isa Core.IntrinsicFunction || any(b -> f === b, PURE_BUILTINS)
end

const PURE_FOREIGNCALLS = (:jl_get_world_counter, :jl_get_tls_world_age, :jl_alloc_genericmemory, :jl_alloc_string,
                           :jl_string_to_genericmemory, :jl_genericmemory_to_string,
                           :jl_symbol_name, :jl_cstr_to_string, :jl_pchar_to_string)

is_pure_foreigncall(stmt::Expr) =
    stmt.head === :foreigncall && foreigncall_name(stmt.args[1]) in PURE_FOREIGNCALLS

function is_throw_call(stmt::Expr)
    stmt.head === :call || return false
    f = stmt.args[1]
    f isa GlobalRef && isdefined(f.mod, f.name) && isconst(f.mod, f.name) && (f = getglobal(f.mod, f.name))
    return f === Core.throw || f === Core.throw_methoderror
end

"""
    drop_unused!(ir) -> IRCode

Remove statements whose results are unused and that the optimizer could have removed (no
effects, no throwing, terminating), and type computations without effects (`apply_type`,
`typejoin`, ...) that it keeps because they may throw. (Natively they run, and do not
throw; here types cannot be built at run time.)
"""
function drop_unused!(ir::CC.IRCode)
    stmts = ir.stmts
    n = length(stmts)
    nuses = zeros(Int, n)
    for idx in 1:n
        for ur in CC.userefs(stmts[idx][:stmt])
            v = ur[]
            v isa Core.SSAValue && (nuses[v.id] += 1)
        end
    end
    work = [idx for idx in 1:n if nuses[idx] == 0]
    while !isempty(work)
        id = pop!(work)
        stmt = stmts[id][:stmt]
        stmt isa Expr && stmt.head in (:call, :invoke) || continue
        stmts[id][:type] === Union{} && continue
        flag = stmts[id][:flag]
        droppable = (flag & CC.IR_FLAGS_REMOVABLE) == CC.IR_FLAGS_REMOVABLE ||
                    is_type_computation(stmt, flag)
        droppable || continue
        for ur in CC.userefs(stmt)
            v = ur[]
            if v isa Core.SSAValue
                nuses[v.id] -= 1
                nuses[v.id] == 0 && push!(work, v.id)
            end
        end
        stmts[id][:stmt] = nothing
        stmts[id][:type] = Nothing
    end
    return ir
end

const TYPE_FUNCTIONS = Any[Base.typejoin, Base.typeintersect, Base.promote_type,
                           Base.promote_typejoin, Base.typesplit, Base.nonnothingtype,
                           Base.nonmissingtype, Base.eltype]

# a builtin computing a type, or a call of a type function (methods of which may be the
# program's, so only without effects)
function is_type_computation(stmt::Expr, flag)
    if stmt.head === :call
        f = stmt.args[1]
        f isa GlobalRef && isdefined(f.mod, f.name) && isconst(f.mod, f.name) && (f = getglobal(f.mod, f.name))
        return f === Core.apply_type || f === Core._typevar || f === Core.typeof
    elseif stmt.head === :invoke
        (flag & CC.IR_FLAG_EFFECT_FREE) != 0 || return false
        f = stmt.args[2]
        f isa GlobalRef && isdefined(f.mod, f.name) && isconst(f.mod, f.name) && (f = getglobal(f.mod, f.name))
        return any(g -> f === g, TYPE_FUNCTIONS)
    end
    return false
end

"""
    prepare_ir(world, mi, exceptions) -> IRCode

The IR of `mi`, ready for structurizing (exceptions as the program uses them).
"""
function prepare_ir(w::ClosedWorld, mi::Core.MethodInstance, exceptions::Symbol=:none)
    ir = get_ircode(w, mi)
    # (where nothing catches, handlers are dropped; where nothing reads what is caught, the
    # exceptions are not built: see `exceptions.jl`)
    exceptions === :none && (ir = strip_exception_handling!(ir))
    exceptions === :values || (ir = trap_throws!(ir))
    ir = drop_unused!(ir)
    return ir
end
