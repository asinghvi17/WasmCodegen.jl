# Generating functions: declarations, the walk of the structured IR, statements, calls and
# changes of representation.

## declarations

"The Julia argument types of the function of `mi`: its signature, varargs packed in a tuple."
function function_argtypes(mi::Core.MethodInstance)
    sig = Any[Base.unwrap_unionall(mi.specTypes).parameters...]
    m = mi.def
    (m isa Method && m.isva) || return sig
    n = Int(m.nargs)
    return Any[sig[1:n-1]..., Tuple{sig[n:end]...}]
end

function function_name(cgm::CGModule, mi::Core.MethodInstance)
    m = mi.def
    base = m isa Method ? string(m.name) : "toplevel"
    return string(replace(base, r"[^A-Za-z0-9_!]" => "_"), "_", length(cgm.mod.funcs) + 1)
end

"""
    get_function!(cgm, mi) -> FuncInfo

The function of `mi`, declared on first use and queued for emission. `mi` must be in
the closed world.
"""
function get_function!(cgm::CGModule, mi::Core.MethodInstance)
    info = get(cgm.funcs, mi, nothing)
    info === nothing || return info
    src = get(cgm.world.sources, mi, nothing)
    src === nothing && unsupported("a call of ", mi, ", which is not in the closed world")
    ci, _ = src
    argtypes = function_argtypes(mi)
    rettype = CC.widenconst(ci.rettype)
    params = ValType[]
    for A in argtypes
        append!(params, valtypes(cgm, A))
    end
    results = layout(cgm, rettype).kind === Bottom ? ValType[] : valtypes(cgm, rettype)
    func = add_func!(cgm.mod, function_name(cgm, mi), params, results)
    info = FuncInfo(mi, func, argtypes, rettype)
    cgm.funcs[mi] = info
    push!(cgm.worklist, info)
    return info
end

"""
    process_worklist!(cgm)

Emit the bodies of the queued functions. A function using an unsupported construct is an
error, or with `on_unsupported = :trap`, a function that traps (recorded in
`cgm.diagnostics`).
"""
function process_worklist!(cgm::CGModule)
    while !isempty(cgm.worklist)
        info = popfirst!(cgm.worklist)
        try
            emit_function!(cgm, info)
        catch err
            err isa Unsupported || rethrow()
            push!(err.context, info.mi)
            cgm.config.on_unsupported === :trap || rethrow()
            push!(cgm.diagnostics, info.mi => err)
            empty!(info.func.body)
            empty!(info.func.locals)
            b = Builder(cgm.mod, info.func)
            unreachable!(b)
            finish!(b)
        end
    end
end

"""
    emit_function!(cgm, info)

Emit the body of the function `info` from the structured IR of its method instance.
"""
function emit_function!(cgm::CGModule, info::FuncInfo)
    ir = prepare_ir(cgm.world, info.mi)
    sci = try
        structurize(ir)
    catch err
        err isa Unsupported && rethrow()
        unsupported("structurizing the IR: ", sprint(showerror, err))
    end
    b = Builder(cgm.mod, info.func)
    fc = FnCtx(cgm, info, sci, b, CGVal[], Dict{Int,Any}(), Dict{Int,CGVal}(),
               LoopTarget[], 0, Vector{CGVal}[])
    bind_arguments!(fc)
    emit_block!(fc, sci.entry)
    is_unreachable(b) || unreachable!(b)
    finish!(b)
    return info
end

# Julia's IR does not require the values of a phi on an edge to be of the phi's type (a
# branch on a type test narrows them), which IRStructurizer's terminator validation
# requires of the yields replacing phis: validate everything else.
# Loops stay `LoopOp`s and `WhileOp`s, with their own exit conditions: promoting them to
# counting `ForOp`s gains nothing on Wasm, and a `ForOp` has neither the signedness of the
# comparison it came from (`ult_int`) nor room for an inclusive bound at `typemax`
function structurize(ir::CC.IRCode)
    sci = StructuredIRCode(ir; validate=false, promote=false)
    IRStructurizer.validate_scf(sci.entry)
    IRStructurizer.validate_no_phis(sci.entry)
    return sci
end

function bind_arguments!(fc::FnCtx)
    p = 0
    for T in fc.info.argtypes
        l = layout(fc, T)
        if l.kind === Ghost
            push!(fc.args, ghost(T, something(ghost_value(T))))
        else
            n = length(l.leaves)
            push!(fc.args, CGVal(T, l.kind, LeafVal[p:p+n-1;]))
            p += n
        end
    end
end

## the walk

"""
    operand(fc, x) -> Union{CGVal,MultiVal}

The value of the operand `x` of a statement.
"""
function operand(fc::FnCtx, @nospecialize(x))
    if x isa Core.SSAValue
        v = get(fc.ssavals, x.id, nothing)
        v === nothing && unsupported("a use of the undefined SSA value %", x.id)
        return v
    elseif x isa Core.Argument
        return fc.args[x.n]
    elseif x isa IRStructurizer.BlockArgument
        return fc.blockargs[x.id]
    elseif x isa IRStructurizer.Undef
        return undef_val(fc, x.type)
    elseif x isa GlobalRef
        c = const_global(fc.cgm.world.world, x.mod, x.name)
        c === nothing || return const_value(fc, something(c))
        return nonconst_global(fc, x)
    elseif x isa QuoteNode
        return const_value(fc, x.value)
    elseif x isa Expr
        unsupported("a nested expression ", x.head)
    end
    return const_value(fc, x)
end

# an operand of a builtin: a constant module is compile-time information only (the module
# of `getglobal`/`setglobal!`), never serialized
function builtin_operand(fc::FnCtx, @nospecialize(x))
    m = x isa QuoteNode ? x.value : x
    if m isa GlobalRef
        c = const_global(fc.cgm.world.world, m.mod, m.name)
        c === nothing || (m = something(c))
    end
    m isa Module && return CGVal(Module, Ghost, LeafVal[], Some{Any}(m))
    return operand(fc, x)
end

function const_global(world::UInt, m::Module, s::Symbol)
    Base.invoke_in_world(world, isconst, m, s) || return nothing
    return Some(Base.invoke_in_world(world, getglobal, m, s))
end

"Emit the statements of `block` and its terminator."
function emit_block!(fc::FnCtx, block)
    for inst in IRStructurizer.instructions(block)
        is_unreachable(fc.b) && return
        idx = inst.ssa_idx
        stmt = inst[:stmt]
        typ = CC.widenconst(inst[:type])
        if stmt isa IRStructurizer.ControlFlowOp
            fc.ssavals[idx] = emit_cfop!(fc, stmt, typ)
        else
            res = emit_stmt_or_trap!(fc, stmt, typ)
            if res !== nothing
                if res isa CGVal && res.kind !== Bottom && typ !== Union{}
                    res = try
                        convert_repr(fc, res, typ)
                    catch err
                        err isa Unsupported || rethrow()
                        push!(err.context, string("the result of ", sprint(show, stmt; context=:limit => true), "::", typ))
                        rethrow()
                    end
                end
                fc.ssavals[idx] = res
            end
            if typ === Union{} && !is_unreachable(fc.b)
                unreachable!(fc.b)
            end
        end
    end
    is_unreachable(fc.b) && return
    emit_terminator!(fc, block.terminator)
end

function emit_terminator!(fc::FnCtx, @nospecialize(term))
    if term isa Core.ReturnNode
        if isdefined(term, :val)
            v = operand(fc, term.val)
            v = convert_repr(fc, v, fc.info.rettype)
            v.kind === Bottom && return
            push_val!(fc, v)
            return!(fc.b)
        else
            unreachable!(fc.b)
        end
    elseif term isa IRStructurizer.YieldOp
        dsts = fc.yields[end]
        length(term.values) == length(dsts) ||
            unsupported("a yield of ", length(term.values), " values to ", length(dsts), " results")
        assign_all!(fc, dsts, term.values)
    elseif term isa IRStructurizer.ContinueOp
        lt = fc.loops[end]
        assign_all!(fc, lt.carries, term.values)
        if lt.iv !== nothing
            push_val!(fc, lt.iv)
            push_val!(fc, convert_repr(fc, operand(fc, lt.step), lt.iv.typ))
            emit!(fc.b, layout(fc, lt.iv.typ).leaves[1].type === I64 ? :i64_add : :i32_add)
            pop_to!(fc, lt.iv)
        end
        br!(fc.b, br_depth(fc, lt.cont))
    elseif term isa IRStructurizer.BreakOp
        lt = fc.loops[end]
        assign_all!(fc, lt.results, term.values)
        br!(fc.b, br_depth(fc, lt.exit))
    elseif term === nothing
        # a block that does not end (its last statement never returns)
    else
        unsupported("the terminator ", typeof(term))
    end
end

# assign values to locals, evaluating all values before assigning (a value may read a
# local that is assigned)
function assign_all!(fc::FnCtx, dsts::Vector{CGVal}, vals)
    srcs = CGVal[convert_repr(fc, operand(fc, v), d.typ) for (v, d) in zip(vals, dsts)]
    for (d, s) in zip(dsts, srcs)
        s.kind === Bottom && continue
        push_val!(fc, s)
    end
    for d in Iterators.reverse(dsts)
        pop_to!(fc, d)
    end
end

# A statement; where it cannot be compiled, a trap, and the error is recorded: with
# `trim = :safe` the compilation fails at the end with every such error (as juliac's
# verifier reports them all), with `trim = :unsafe` the trap stays.
function emit_stmt_or_trap!(fc::FnCtx, @nospecialize(stmt), @nospecialize(typ))
    # (a statement that fails leaves no partial code: its instructions are dropped)
    mark = length(fc.b.func.body)
    stack = copy(fc.b.stack)
    frames = copy(fc.b.frames)
    inits = copy(fc.b.inits)
    depth = fc.depth
    try
        return emit_stmt!(fc, stmt, typ)
    catch err
        err isa Unsupported || rethrow()
        resize!(fc.b.func.body, mark)
        fc.b.stack = stack
        fc.b.frames = frames
        fc.b.inits = inits
        fc.depth = depth
        push!(err.context, string("the statement ", sprint(show, stmt; context=:limit => true), "::", typ))
        push!(err.context, fc.info.mi)
        push!(fc.cgm.diagnostics, fc.info.mi => err)
        unreachable!(fc.b)
        return bottom()
    end
end

## structured control flow

result_types(@nospecialize(typ)) =
    typ isa DataType && typ <: Tuple ? Any[typ.parameters...] : Any[]

function new_vals!(fc::FnCtx, types)
    return CGVal[new_val!(fc, T) for T in types]
end

function emit_cfop!(fc::FnCtx, op::IRStructurizer.IfOp, @nospecialize(typ))
    results = new_vals!(fc, result_types(typ))
    c = convert_repr(fc, operand(fc, op.condition), Bool)
    if isconstant(c)
        # a branch on a constant: only one arm
        push!(fc.yields, results)
        emit_region!(fc, constant_value(c) ? op.then_region : op.else_region)
        pop!(fc.yields)
        return MultiVal(results)
    end
    push_val!(fc, c)
    if!(fc.b)
    open_label!(fc)
    push!(fc.yields, results)
    emit_region!(fc, op.then_region)
    else!(fc.b)
    emit_region!(fc, op.else_region)
    pop!(fc.yields)
    end!(fc.b)
    close_label!(fc)
    return MultiVal(results)
end

# emit a region in its own scope of block arguments
function emit_region!(fc::FnCtx, block)
    emit_block!(fc, block)
end

function bind_block_args!(fc::FnCtx, args, vals::Vector{CGVal})
    for (a, v) in zip(args, vals)
        fc.blockargs[a.id] = v
    end
end

function emit_cfop!(fc::FnCtx, op::IRStructurizer.LoopOp, @nospecialize(typ))
    carries = new_vals!(fc, [CC.widenconst(a.type) for a in op.body.args])
    assign_all!(fc, carries, op.init_values)
    bind_block_args!(fc, op.body.args, carries)
    results = new_vals!(fc, result_types(typ))
    block!(fc.b); exit = open_label!(fc)
    loop!(fc.b); cont = open_label!(fc)
    push!(fc.loops, LoopTarget(exit, cont, carries, results, nothing, nothing))
    emit_block!(fc, op.body)
    pop!(fc.loops)
    # falling off the end of the body does not happen (it continues or breaks)
    is_unreachable(fc.b) || unreachable!(fc.b)
    end!(fc.b); close_label!(fc)
    end!(fc.b); close_label!(fc)
    return MultiVal(results)
end

function emit_cfop!(fc::FnCtx, op::IRStructurizer.ForOp, @nospecialize(typ))
    ivT = CC.widenconst(op.iv_arg.type)
    iv = new_val!(fc, ivT)
    assign!(fc, iv, convert_repr(fc, operand(fc, op.lower), ivT))
    fc.blockargs[op.iv_arg.id] = iv
    carries = new_vals!(fc, [CC.widenconst(a.type) for a in op.body.args])
    assign_all!(fc, carries, op.init_values)
    bind_block_args!(fc, op.body.args, carries)
    upper = convert_repr(fc, operand(fc, op.upper), ivT)
    is64 = layout(fc, ivT).leaves[1].type === I64
    block!(fc.b); exit = open_label!(fc)
    loop!(fc.b); cont = open_label!(fc)
    # exit unless iv < upper (signed)
    push_val!(fc, iv)
    push_val!(fc, upper)
    emit!(fc.b, is64 ? :i64_ge_s : :i32_ge_s)
    br_if!(fc.b, br_depth(fc, exit))
    push!(fc.loops, LoopTarget(exit, cont, carries, carries, iv, op.step))
    emit_block!(fc, op.body)
    pop!(fc.loops)
    is_unreachable(fc.b) || unreachable!(fc.b)
    end!(fc.b); close_label!(fc)
    end!(fc.b); close_label!(fc)
    return MultiVal(carries)
end

function emit_cfop!(fc::FnCtx, op::IRStructurizer.WhileOp, @nospecialize(typ))
    carries = new_vals!(fc, [CC.widenconst(a.type) for a in op.before.args])
    assign_all!(fc, carries, op.init_values)
    bind_block_args!(fc, op.before.args, carries)
    results = new_vals!(fc, result_types(typ))
    block!(fc.b); exit = open_label!(fc)
    loop!(fc.b); cont = open_label!(fc)
    push!(fc.loops, LoopTarget(exit, cont, carries, results, nothing, nothing))
    # the before region, up to its condition
    for inst in IRStructurizer.instructions(op.before)
        is_unreachable(fc.b) && break
        stmt = inst[:stmt]
        typ_i = CC.widenconst(inst[:type])
        if stmt isa IRStructurizer.ControlFlowOp
            fc.ssavals[inst.ssa_idx] = emit_cfop!(fc, stmt, typ_i)
        else
            res = emit_stmt_or_trap!(fc, stmt, typ_i)
            res isa CGVal && res.kind !== Bottom && typ_i !== Union{} &&
                (res = convert_repr(fc, res, typ_i))
            res === nothing || (fc.ssavals[inst.ssa_idx] = res)
            typ_i === Union{} && !is_unreachable(fc.b) && unreachable!(fc.b)
        end
    end
    if !is_unreachable(fc.b)
        term = op.before.terminator
        if term isa IRStructurizer.ConditionOp
            c = convert_repr(fc, operand(fc, term.condition), Bool)
            # on false: the condition's values are the results
            push_val!(fc, c)
            emit!(fc.b, :i32_eqz)
            if!(fc.b); open_label!(fc)
            assign_all!(fc, results, term.args)
            br!(fc.b, br_depth(fc, exit))
            end!(fc.b); close_label!(fc)
            # on true: they are the arguments of the after region
            afterargs = new_vals!(fc, [CC.widenconst(a.type) for a in op.after.args])
            assign_all!(fc, afterargs, term.args)
            bind_block_args!(fc, op.after.args, afterargs)
            # the after region yields the next carried values
            push!(fc.yields, carries)
            emit_block!(fc, op.after)
            pop!(fc.yields)
            is_unreachable(fc.b) || br!(fc.b, br_depth(fc, cont))
        else
            emit_terminator!(fc, term)
        end
    end
    pop!(fc.loops)
    is_unreachable(fc.b) || unreachable!(fc.b)
    end!(fc.b); close_label!(fc)
    end!(fc.b); close_label!(fc)
    return MultiVal(results)
end

## statements

const NOOP_HEADS = (:code_coverage_effect, :meta, :inbounds, :loopinfo, :aliasscope,
                    :popaliasscope, :latestworld, :gc_preserve_end)

"""
    emit_stmt!(fc, stmt, typ) -> Union{Nothing,CGVal,MultiVal}

Emit a (non control flow) statement of type `typ`, returning its value.
"""
function emit_stmt!(fc::FnCtx, @nospecialize(stmt), @nospecialize(typ))
    if stmt isa Expr
        return emit_expr!(fc, stmt, typ)
    elseif stmt isa Core.PiNode
        v = operand(fc, stmt.val)
        return convert_repr(fc, v, typ)
    elseif stmt === nothing
        return nothing
    elseif stmt isa Core.GotoNode || stmt isa Core.GotoIfNot || stmt isa Core.PhiNode
        unsupported("unstructured control flow (", typeof(stmt), ")")
    elseif stmt isa Core.EnterNode || stmt isa Core.UpsilonNode || stmt isa Core.PhiCNode
        unsupported("exception handling (", typeof(stmt), ")")
    else
        return operand(fc, stmt)
    end
end

function emit_expr!(fc::FnCtx, ex::Expr, @nospecialize(typ))
    head = ex.head
    if head === :call
        return emit_call!(fc, ex, typ)
    elseif head === :invoke
        return emit_invoke!(fc, ex, typ)
    elseif head === :new
        T = operand(fc, ex.args[1])
        isconstant(T) || unsupported("`new` of a type that is not known at compile time")
        args = CGVal[operand(fc, a) for a in ex.args[2:end]]
        return emit_new!(fc, constant_value(T), args)
    elseif head === :splatnew
        T = operand(fc, ex.args[1])
        isconstant(T) || unsupported("`splatnew` of a type that is not known at compile time")
        tup = operand(fc, ex.args[2])
        return emit_new!(fc, constant_value(T), tuple_elements(fc, tup))
    elseif head === :boundscheck
        cb = Base.JLOptions().check_bounds
        cb == 1 && return const_value(fc, true)
        cb == 2 && return const_value(fc, false)
        return const_value(fc, isempty(ex.args) ? true : ex.args[1] !== false)
    elseif head === :static_parameter
        return const_value(fc, fc.info.mi.sparam_vals[ex.args[1]::Int])
    elseif head === :foreigncall
        return emit_foreigncall!(fc, ex, typ)
    elseif head in NOOP_HEADS
        return nothing
    elseif head === :gc_preserve_begin
        return ghost(Nothing, nothing)
    elseif head === :throw_undef_if_not
        c = convert_repr(fc, operand(fc, ex.args[2]), Bool)
        isconstant(c) && constant_value(c) && return nothing
        push_val!(fc, c)
        emit!(fc.b, :i32_eqz)
        if!(fc.b); unreachable!(fc.b); end!(fc.b)
        return nothing
    elseif head === :isdefined
        x = ex.args[1]
        x isa GlobalRef && return isdefined_global!(fc, x)
        unsupported("isdefined of ", x)
    elseif head === :the_exception
        unreachable!(fc.b)
        return bottom()
    else
        unsupported("the expression head ", head)
    end
end

## calls

function emit_call!(fc::FnCtx, ex::Expr, @nospecialize(typ))
    f = operand(fc, ex.args[1])
    (f isa CGVal && isconstant(f)) ||
        unsupported("a call of a function value of type ", f isa CGVal ? f.typ : f)
    fv = constant_value(f)
    args = Any[fv isa Core.Builtin ? builtin_operand(fc, a) : operand(fc, a) for a in ex.args[2:end]]
    if fv isa Core.IntrinsicFunction
        return emit_intrinsic!(fc, fv, args, typ)
    elseif fv isa Core.Builtin
        return emit_builtin!(fc, fv, args, typ)
    elseif typ === Union{}
        # an error path whose call was not resolved
        unreachable!(fc.b)
        return bottom()
    else
        unsupported("a dynamic call of ", fv, " with argument types (",
                    join([a isa CGVal ? string(a.typ) : "?" for a in args], ", "), ")")
    end
end

function emit_invoke!(fc::FnCtx, ex::Expr, @nospecialize(typ))
    target = ex.args[1]
    mi = target isa Core.CodeInstance ? CC.get_ci_mi(target) : target
    mi isa Core.MethodInstance || unsupported("an invoke of ", target)
    r = emit_intrinsic_call!(fc, mi, ex, typ)
    r === nothing || return r
    info = get_function!(fc.cgm, mi)
    args = CGVal[operand(fc, a) for a in ex.args[2:end]]
    return emit_call_info!(fc, info, args)
end

"""
    emit_call_info!(fc, info, args) -> CGVal

Call the function `info` with the values `args` (the function object first).
"""
function emit_call_info!(fc::FnCtx, info::FuncInfo, args::Vector{CGVal})
    m = info.mi.def
    if m isa Method && m.isva
        n = Int(m.nargs)
        rest = args[n:end]
        T = info.argtypes[end]
        args = CGVal[args[1:n-1]..., make_tuple(fc, T, rest)]
    end
    length(args) == length(info.argtypes) ||
        unsupported("a call of ", info.mi, " with ", length(args), " arguments")
    for (a, T) in zip(args, info.argtypes)
        v = convert_repr(fc, a, T)
        v.kind === Bottom && return v
        push_val!(fc, v)
    end
    call!(fc.b, info.func)
    if layout(fc, info.rettype).kind === Bottom
        unreachable!(fc.b)
        return bottom()
    end
    return pop_val!(fc, info.rettype)
end

## changes of representation

"""
    convert_repr(fc, v, T) -> CGVal

The value `v` in the representation of type `T` (`v` is of type `T`, or of a type whose
values may be of type `T`): boxing an inline value for an abstract type, unboxing a boxed
value for a concrete one.
"""
function convert_repr(fc::FnCtx, v, @nospecialize(T))
    v isa MultiVal && unsupported("a use of the results of a control flow operation as a value")
    v = v::CGVal
    v.typ === T && return v
    v.kind === Bottom && return v
    lt = layout(fc, T)
    lv = layout(fc, v.typ)
    if lt.kind === Bottom
        is_unreachable(fc.b) || unreachable!(fc.b)
        return bottom()
    elseif lt.kind === Ghost
        return ghost(T, something(ghost_value(T)))
    elseif lt.kind === Inline
        if lv.kind === Inline
            length(lv.leaves) == length(lt.leaves) &&
                all(i -> lv.leaves[i].type == lt.leaves[i].type, eachindex(lt.leaves)) ||
                unsupported("a conversion from ", v.typ, " to ", T)
            return CGVal(T, Inline, v.leaves, v.constant, v.origin)
        elseif lv.kind === Boxed && lv.elements !== nothing
            # a tuple of unknown length (an array) as a tuple of known length: its elements
            leaves = LeafVal[]
            for i in 1:fieldcount(T)
                e = convert_repr(fc, tuple_array_get!(fc, v, const_value(fc, i)), fieldtype(T, i))
                append!(leaves, e.leaves)
            end
            return CGVal(T, Inline, leaves)
        elseif lv.kind === Boxed
            return unbox!(fc, v, T)
        else
            unsupported("a conversion from ", v.typ, " to ", T)
        end
    else # Boxed
        if lt.wtype == fc.cgm.types.jlvalue
            # an abstract type: any object
            if lv.kind === Boxed && is_jlvalue_type(fc.cgm.types, v.typ)
                return CGVal(T, Boxed, v.leaves, v.constant)
            end
            return box!(fc, v, T)
        elseif lv.kind === Boxed && lv.wtype == lt.wtype
            return CGVal(T, Boxed, v.leaves, v.constant)
        elseif lt.elements !== nothing && lv.kind in (Inline, Ghost) && v.typ <: Tuple
            # a tuple of known length as a tuple of unknown length (an array)
            return new_tuple_array!(fc, T, CGVal[get_field(fc, v, i) for i in 1:fieldcount(v.typ)])
        elseif lv.kind === Boxed && lv.wtype == fc.cgm.types.jlvalue
            return unbox!(fc, v, T)
        else
            unsupported("a conversion from ", v.typ, " to ", T)
        end
    end
end

"""
    box!(fc, v, T) -> CGVal

The value `v` as an object (a `\$JlValue`), of the abstract type `T`.
"""
function box!(fc::FnCtx, v::CGVal, @nospecialize(T))
    ts = fc.cgm.types
    S = v.typ
    lv = layout(fc, S)
    if isconstant(v)
        g = boxed_object_global!(fc.cgm.image, constant_value(v))
        return CGVal(T, Boxed, LeafVal[Inst(:global_get, g)], v.constant)
    end
    lv.kind === Ghost && unsupported("boxing the ghost ", S, " without its value")
    box = box_type!(ts, S)
    emit!(fc.b, :i32_const, typeid!(ts, S))
    emit!(fc.b, :i32_const, 0)
    push_val!(fc, v)
    emit!(fc.b, :struct_new, box)
    r = new_local!(fc, jlvalue_ref(ts))
    emit!(fc.b, :local_set, r)
    return CGVal(T, Boxed, LeafVal[r])
end

"""
    unbox!(fc, v, T) -> CGVal

The object `v` (a `\$JlValue`) as a value of the concrete type `T` (which it is).
"""
function unbox!(fc::FnCtx, v::CGVal, @nospecialize(T))
    ts = fc.cgm.types
    lt = layout(fc, T)
    if lt.kind === Boxed && is_jlvalue_type(ts, T)
        push_val!(fc, v)
        emit!(fc.b, :ref_cast_null, lt.wtype)
        return pop_val!(fc, T)
    end
    # an inline value, a Memory or a String: in a box
    box = box_type!(ts, T)
    push_val!(fc, v)
    emit!(fc.b, :ref_cast_null, box)
    tmp = new_local!(fc, RefType(box, true))
    emit!(fc.b, :local_set, tmp)
    fields = (typedef(ts.mod, box).comp::StructType).fields
    for i in HEADER_FIELDS+1:length(fields)
        emit!(fc.b, :local_get, tmp)
        st = fields[i].storage
        emit!(fc.b, st isa PackedType ? :struct_get_u : :struct_get, box, i - 1)
    end
    return pop_val!(fc, T)
end
