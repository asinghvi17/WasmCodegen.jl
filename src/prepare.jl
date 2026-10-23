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

Where throwing traps: every statement that always throws (a `throw`, or a call of a
function that never returns) becomes `throw(nothing)`, and the statements computing
values used only to be thrown (exception objects and their messages) are removed, with
their effects. The exception is never built: its construction and the code formatting its
message are not compiled.
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
        stmts[idx][:type] === Union{} || continue
        stmt isa Expr && stmt.head in (:call, :invoke, :foreigncall) || continue
        is_throw_call(stmt) && length(stmt.args) == 2 && stmt.args[2] === nothing && continue
        release!(stmt)
        stmts[idx][:stmt] = Expr(:call, GlobalRef(Core, :throw), nothing)
    end
    while !isempty(work)
        id = pop!(work)
        stmt = stmts[id][:stmt]
        # only plain computations: control flow stays
        (stmt isa Expr || stmt isa Core.PiNode) || continue
        stmt isa Expr && stmt.head in (:call, :invoke, :new, :foreigncall, :splatnew) || continue
        release!(stmt)
        stmts[id][:stmt] = nothing
        stmts[id][:type] = Nothing
    end
    return ir
end

is_throw_call(stmt::Expr) = stmt.head === :call &&
    (stmt.args[1] === GlobalRef(Core, :throw) || stmt.args[1] === Core.throw ||
     stmt.args[1] === GlobalRef(Base, :throw))

"""
    prepare_ir(world, mi) -> IRCode

The IR of `mi`, ready for structurizing: exception handling removed, throws trapping.
"""
function prepare_ir(w::ClosedWorld, mi::Core.MethodInstance)
    ir = get_ircode(w, mi)
    ir = strip_exception_handling!(ir)
    ir = trap_throws!(ir)
    return ir
end
