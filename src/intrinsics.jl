# Intrinsic functions (`Core.Intrinsics`).
#
# Integers narrower than 32 bits live in an `i32`, zero-extended (their bits, and zeros
# above): the arithmetic that can set the bits above masks its result, and operations that
# depend on the sign sign-extend their operands first. 128-bit integers are not supported
# yet.

const II = Core.Intrinsics

nbits(@nospecialize(T)) = 8 * sizeof(T)

# the Wasm type of a primitive type's single leaf
function prim_wtype(fc::FnCtx, @nospecialize(T))
    l = layout(fc, T)
    (l.kind === Inline && length(l.leaves) == 1) ||
        unsupported("the intrinsic on values of type ", T)
    return l.leaves[1].type
end

is64(t::ValType) = t === I64 || t === F64
wprefix(t::ValType) = t === I32 ? "i32" : t === I64 ? "i64" : t === F32 ? "f32" : "f64"
wop(t::ValType, op::AbstractString) = Symbol(wprefix(t), "_", op)

"Mask the integer of type `T` on the stack to its bits (for types narrower than 32 bits)."
function mask!(fc::FnCtx, @nospecialize(T))
    n = nbits(T)
    T === Bool && (n = 1)
    if n < 32
        emit!(fc.b, :i32_const, (1 << n) - 1)
        emit!(fc.b, :i32_and)
    end
end

"Sign-extend the integer of type `T` on the stack (for types narrower than 32 bits)."
function sext!(fc::FnCtx, @nospecialize(T))
    n = nbits(T)
    if n == 8
        emit!(fc.b, :i32_extend8_s)
    elseif n == 16
        emit!(fc.b, :i32_extend16_s)
    end
end

function push_signed!(fc::FnCtx, v::CGVal)
    push_val!(fc, v)
    sext!(fc, v.typ)
end

const INT_BINOPS = Dict(II.add_int => "add", II.sub_int => "sub", II.mul_int => "mul",
                        II.and_int => "and", II.or_int => "or", II.xor_int => "xor",
                        II.udiv_int => "div_u", II.urem_int => "rem_u",
                        II.sdiv_int => "div_s", II.srem_int => "rem_s")
const INT_CMPS = Dict(II.eq_int => "eq", II.ne_int => "ne", II.slt_int => "lt_s",
                      II.sle_int => "le_s", II.ult_int => "lt_u", II.ule_int => "le_u")
const FLOAT_BINOPS = Dict(II.add_float => "add", II.sub_float => "sub",
                          II.mul_float => "mul", II.div_float => "div",
                          II.add_float_fast => "add", II.sub_float_fast => "sub",
                          II.mul_float_fast => "mul", II.div_float_fast => "div",
                          II.copysign_float => "copysign")
# IEEE minimum/maximum (NaN if either is, -0.0 < 0.0): Wasm's min/max
for (name, op) in ((:min_float, "min"), (:max_float, "max"), (:min_float_fast, "min"),
                   (:max_float_fast, "max"))
    isdefined(II, name) && (FLOAT_BINOPS[getfield(II, name)] = op)
end
const FLOAT_CMPS = Dict(II.eq_float => "eq", II.ne_float => "ne", II.lt_float => "lt",
                        II.le_float => "le", II.eq_float_fast => "eq",
                        II.ne_float_fast => "ne", II.lt_float_fast => "lt",
                        II.le_float_fast => "le")
const FLOAT_UNOPS = Dict(II.neg_float => "neg", II.neg_float_fast => "neg",
                         II.abs_float => "abs", II.sqrt_llvm => "sqrt",
                         II.sqrt_llvm_fast => "sqrt", II.floor_llvm => "floor",
                         II.ceil_llvm => "ceil", II.trunc_llvm => "trunc",
                         II.rint_llvm => "nearest")

# intrinsics on pointers themselves (others act on their addresses)
const PTR_INTRINSICS = Any[II.add_ptr, II.sub_ptr, II.bitcast, II.pointerref, II.pointerset,
                           II.atomic_pointerref, II.atomic_pointerset]
# loads and stores through pointers: never evaluated at compile time (a constant pointer is
# an address of the build process), and of any isbits type (see pointers.jl)
const NO_FOLD = Any[II.have_fma, II.pointerref, II.pointerset, II.atomic_pointerref,
                    II.atomic_pointerset]

"""
    emit_intrinsic!(fc, f, args, typ) -> CGVal

Emit the intrinsic `f` on the values `args`, of result type `typ`.
"""
function emit_intrinsic!(fc::FnCtx, f::Core.IntrinsicFunction, args::Vector{Any}, @nospecialize(typ))
    args = CGVal[a for a in args]
    if !(f in PTR_INTRINSICS) && (any(a -> is_ptr_type(a.typ), args) || is_ptr_type(typ))
        # integer operations on pointers: of their addresses
        r = emit_intrinsic!(fc, f, Any[is_ptr_type(a.typ) ? ptr_address(a) : a for a in args],
                            is_ptr_type(typ) ? UInt64 : typ)
        return is_ptr_type(typ) ? int_ptr!(fc, typ, r) : r
    end
    if all(isconstant, args) && !(f in NO_FOLD)
        # fold (as inference would have, had it known)
        try
            return const_value(fc, f(map(constant_value, args)...))
        catch
        end
    end
    if !(f in NO_FOLD) && (any(a -> is128(a.typ), args) || (typ isa Type && is128(typ) && f !== II.bitcast))
        r = emit_intrinsic128!(fc, f, args, typ)
        r === nothing || return r
    end
    if haskey(INT_BINOPS, f)
        a, b = args
        T = a.typ
        t = prim_wtype(fc, T)
        signed = f === II.sdiv_int || f === II.srem_int
        signed ? push_signed!(fc, a) : push_val!(fc, a)
        signed ? push_signed!(fc, b) : push_val!(fc, b)
        emit!(fc.b, wop(t, INT_BINOPS[f]))
        f in (II.add_int, II.sub_int, II.mul_int, II.sdiv_int, II.srem_int) && mask!(fc, T)
        return pop_val!(fc, T)
    elseif haskey(INT_CMPS, f)
        a, b = args
        t = prim_wtype(fc, a.typ)
        signed = f === II.slt_int || f === II.sle_int
        signed ? push_signed!(fc, a) : push_val!(fc, a)
        signed ? push_signed!(fc, b) : push_val!(fc, b)
        if t isa RefType
            emit!(fc.b, :ref_eq)
            f === II.ne_int && emit!(fc.b, :i32_eqz)
        else
            emit!(fc.b, wop(t, INT_CMPS[f]))
        end
        return pop_val!(fc, Bool)
    elseif haskey(FLOAT_BINOPS, f)
        a, b = args
        t = prim_wtype(fc, a.typ)
        push_val!(fc, a); push_val!(fc, b)
        emit!(fc.b, wop(t, FLOAT_BINOPS[f]))
        return pop_val!(fc, a.typ)
    elseif haskey(FLOAT_CMPS, f)
        a, b = args
        t = prim_wtype(fc, a.typ)
        push_val!(fc, a); push_val!(fc, b)
        emit!(fc.b, wop(t, FLOAT_CMPS[f]))
        return pop_val!(fc, Bool)
    elseif haskey(FLOAT_UNOPS, f)
        a = args[1]
        t = prim_wtype(fc, a.typ)
        push_val!(fc, a)
        emit!(fc.b, wop(t, FLOAT_UNOPS[f]))
        return pop_val!(fc, a.typ)
    elseif f === II.fma_float
        # no fused multiply-add on Wasm: Base's exact emulation
        return call_runtime!(fc, Base.fma_emulated, args)
    elseif f === II.muladd_float
        a, b, c = args
        t = prim_wtype(fc, a.typ)
        push_val!(fc, a); push_val!(fc, b)
        emit!(fc.b, wop(t, "mul"))
        push_val!(fc, c)
        emit!(fc.b, wop(t, "add"))
        return pop_val!(fc, a.typ)
    elseif f === II.neg_int
        a = args[1]
        t = prim_wtype(fc, a.typ)
        emit!(fc.b, wop(t, "const"), 0)
        push_val!(fc, a)
        emit!(fc.b, wop(t, "sub"))
        mask!(fc, a.typ)
        return pop_val!(fc, a.typ)
    elseif f === II.not_int
        a = args[1]
        t = prim_wtype(fc, a.typ)
        push_val!(fc, a)
        if a.typ === Bool
            emit!(fc.b, :i32_eqz)
        else
            emit!(fc.b, wop(t, "const"), -1)
            emit!(fc.b, wop(t, "xor"))
            mask!(fc, a.typ)
        end
        return pop_val!(fc, a.typ)
    elseif f === II.shl_int || f === II.lshr_int || f === II.ashr_int
        return emit_shift!(fc, f, args[1], args[2])
    elseif f === II.bitcast
        return emit_bitcast!(fc, constant_value(args[1]), args[2])
    elseif f === II.sext_int || f === II.zext_int || f === II.trunc_int
        return emit_int_conversion!(fc, f, constant_value(args[1]), args[2])
    elseif f === II.sitofp || f === II.uitofp
        R = constant_value(args[1]); a = args[2]
        tr, ta = prim_wtype(fc, R), prim_wtype(fc, a.typ)
        f === II.sitofp ? push_signed!(fc, a) : push_val!(fc, a)
        emit!(fc.b, Symbol(wprefix(tr), "_convert_", wprefix(ta), f === II.sitofp ? "_s" : "_u"))
        return pop_val!(fc, R)
    elseif f === II.fptosi || f === II.fptoui
        # Julia checks the range before converting (`trunc`): the saturating conversions
        # never trap where the result is undefined
        R = constant_value(args[1]); a = args[2]
        tr, ta = prim_wtype(fc, R), prim_wtype(fc, a.typ)
        push_val!(fc, a)
        emit!(fc.b, Symbol(wprefix(tr), "_trunc_sat_", wprefix(ta), f === II.fptosi ? "_s" : "_u"))
        mask!(fc, R)
        return pop_val!(fc, R)
    elseif f === II.fptrunc || f === II.fpext
        R = constant_value(args[1]); a = args[2]
        if R === Float32 && a.typ === Float64
            push_val!(fc, a); emit!(fc.b, :f32_demote_f64)
        elseif R === Float64 && a.typ === Float32
            push_val!(fc, a); emit!(fc.b, :f64_promote_f32)
        else
            unsupported(f, " from ", a.typ, " to ", R)
        end
        return pop_val!(fc, R)
    elseif f === II.fpiseq
        # isequal on floats: the same bits, or both NaN
        a, b = args
        t = prim_wtype(fc, a.typ)
        it = t === F64 ? I64 : I32
        push_val!(fc, a); emit!(fc.b, Symbol(wprefix(it), "_reinterpret_", wprefix(t)))
        push_val!(fc, b); emit!(fc.b, Symbol(wprefix(it), "_reinterpret_", wprefix(t)))
        emit!(fc.b, wop(it, "eq"))
        push_val!(fc, a); push_val!(fc, a); emit!(fc.b, wop(t, "ne"))
        push_val!(fc, b); push_val!(fc, b); emit!(fc.b, wop(t, "ne"))
        emit!(fc.b, :i32_and)
        emit!(fc.b, :i32_or)
        return pop_val!(fc, Bool)
    elseif f === II.ctpop_int || f === II.ctlz_int || f === II.cttz_int
        a = args[1]
        T = a.typ
        t = prim_wtype(fc, T)
        n = nbits(T)
        push_val!(fc, a)
        if f === II.ctpop_int
            emit!(fc.b, wop(t, "popcnt"))
        elseif f === II.ctlz_int
            emit!(fc.b, wop(t, "clz"))
            if n < 32
                emit!(fc.b, :i32_const, 32 - n)
                emit!(fc.b, :i32_sub)
            end
        else
            if n < 32
                emit!(fc.b, :i32_const, 1 << n)
                emit!(fc.b, :i32_or)
            end
            emit!(fc.b, wop(t, "ctz"))
        end
        return pop_val!(fc, T)
    elseif f === II.flipsign_int
        # y < 0 ? -x : x
        x, y = args
        T = x.typ
        t = prim_wtype(fc, T)
        emit!(fc.b, wop(t, "const"), 0)
        push_val!(fc, x)
        emit!(fc.b, wop(t, "sub"))
        mask!(fc, T)
        push_val!(fc, x)
        push_signed!(fc, y)
        emit!(fc.b, wop(prim_wtype(fc, y.typ), "const"), 0)
        emit!(fc.b, wop(prim_wtype(fc, y.typ), "lt_s"))
        emit!(fc.b, :select)
        return pop_val!(fc, T)
    elseif f === II.bswap_int
        return emit_bswap!(fc, args[1])
    elseif f in (II.checked_sadd_int, II.checked_uadd_int, II.checked_ssub_int,
                 II.checked_usub_int, II.checked_smul_int, II.checked_umul_int)
        return emit_checked!(fc, f, args[1], args[2])
    elseif f in (II.checked_sdiv_int, II.checked_udiv_int, II.checked_srem_int,
                 II.checked_urem_int)
        return emit_checked_div!(fc, f, args[1], args[2])
    elseif f === II.add_ptr || f === II.sub_ptr
        return ptr_offset!(fc, args[1], args[2], f === II.add_ptr)
    elseif f === II.have_fma
        return const_value(fc, false)
    elseif f === II.atomic_fence
        return ghost(Nothing, nothing)
    elseif f === II.pointerref || f === II.atomic_pointerref
        p = args[1]
        return ptr_load!(fc, p, f === II.pointerref ? args[2] : const_value(fc, 1), eltype(p.typ))
    elseif f === II.atomic_pointerset || f === II.pointerset
        p = args[1]
        T = eltype(p.typ)
        v = T === Cvoid || !isconcretetype(T) ? args[2] : convert_repr(fc, args[2], T)
        return ptr_store!(fc, p, v, f === II.pointerset ? args[3] : const_value(fc, 1))
    end
    unsupported("the intrinsic ", f)
end

function emit_shift!(fc::FnCtx, f, x::CGVal, y::CGVal)
    T = x.typ
    t = prim_wtype(fc, T)
    ty = prim_wtype(fc, y.typ)
    n = nbits(T)
    # the shift count, as an unsigned integer of `t`'s width, saturated to n
    cnt = new_local!(fc, t)
    push_val!(fc, y)
    if ty === I64
        emit!(fc.b, :i64_const, n)
        push_val!(fc, y)
        emit!(fc.b, :i64_const, n)
        emit!(fc.b, :i64_lt_u)
        emit!(fc.b, :select)
        t === I32 && emit!(fc.b, :i32_wrap_i64)
    else
        emit!(fc.b, :i32_const, n)
        push_val!(fc, y)
        emit!(fc.b, :i32_const, n)
        emit!(fc.b, :i32_lt_u)
        emit!(fc.b, :select)
        t === I64 && emit!(fc.b, :i64_extend_i32_u)
    end
    emit!(fc.b, :local_set, cnt)
    if f === II.ashr_int
        # counts of n or more give the sign: shift by n-1
        push_signed!(fc, x)
        emit!(fc.b, :local_get, cnt)
        emit!(fc.b, wop(t, "const"), n - 1)
        emit!(fc.b, :local_get, cnt)
        emit!(fc.b, wop(t, "const"), n - 1)
        emit!(fc.b, wop(t, "lt_u"))
        emit!(fc.b, :select)
        emit!(fc.b, wop(t, "shr_s"))
        mask!(fc, T)
    else
        # counts of n or more give 0
        push_val!(fc, x)
        emit!(fc.b, :local_get, cnt)
        emit!(fc.b, wop(t, f === II.shl_int ? "shl" : "shr_u"))
        f === II.shl_int && mask!(fc, T)
        emit!(fc.b, wop(t, "const"), 0)
        emit!(fc.b, :local_get, cnt)
        emit!(fc.b, wop(t, "const"), n)
        emit!(fc.b, wop(t, "lt_u"))
        emit!(fc.b, :select)
    end
    return pop_val!(fc, T)
end

function emit_bitcast!(fc::FnCtx, @nospecialize(R), x::CGVal)
    S = x.typ
    if is_ptr_type(R) && is_ptr_type(S)
        return CGVal(R, Inline, x.leaves, nothing, x.origin)
    elseif is_ptr_type(R)
        return int_ptr!(fc, R, x)
    elseif is_ptr_type(S)
        x = ptr_address(x)
        S = UInt64
    end
    sizeof(R) == sizeof(S) || unsupported("bitcast from ", S, " to ", R)
    lr, ls = layout(fc, R), layout(fc, S)
    tr, ts = lr.leaves[1].type, ls.leaves[1].type
    length(lr.leaves) == 1 || unsupported("bitcast to ", R)
    tr === ts && return CGVal(R, Inline, x.leaves, nothing, x.origin)
    push_val!(fc, x)
    emit!(fc.b, Symbol(wprefix(tr), "_reinterpret_", wprefix(ts)))
    return pop_val!(fc, R)
end

function emit_int_conversion!(fc::FnCtx, f, @nospecialize(R), x::CGVal)
    S = x.typ
    tr, ts = prim_wtype(fc, R), prim_wtype(fc, S)
    if f === II.trunc_int
        push_val!(fc, x)
        tr === I32 && ts === I64 && emit!(fc.b, :i32_wrap_i64)
        mask!(fc, R)
    elseif f === II.sext_int
        push_signed!(fc, x)
        tr === I64 && ts === I32 && emit!(fc.b, :i64_extend_i32_s)
        mask!(fc, R)
    else
        push_val!(fc, x)
        tr === I64 && ts === I32 && emit!(fc.b, :i64_extend_i32_u)
    end
    return pop_val!(fc, R)
end

function emit_bswap!(fc::FnCtx, x::CGVal)
    T = x.typ
    n = nbits(T)
    n == 8 && return x
    t = prim_wtype(fc, T)
    acc = new_local!(fc, t)
    emit!(fc.b, wop(t, "const"), 0)
    emit!(fc.b, :local_set, acc)
    for k in 0:(n ÷ 8 - 1)
        # byte k goes to byte n/8-1-k
        push_val!(fc, x)
        emit!(fc.b, wop(t, "const"), 8k)
        emit!(fc.b, wop(t, "shr_u"))
        emit!(fc.b, wop(t, "const"), 0xff)
        emit!(fc.b, wop(t, "and"))
        emit!(fc.b, wop(t, "const"), 8 * (n ÷ 8 - 1 - k))
        emit!(fc.b, wop(t, "shl"))
        emit!(fc.b, :local_get, acc)
        emit!(fc.b, wop(t, "or"))
        emit!(fc.b, :local_set, acc)
    end
    emit!(fc.b, :local_get, acc)
    return pop_val!(fc, T)
end

"""
    emit_checked!(fc, f, a, b) -> CGVal

A checked arithmetic intrinsic: the result and whether it overflowed, a `Tuple{T,Bool}`.
"""
function emit_checked!(fc::FnCtx, f, a::CGVal, b::CGVal)
    T = a.typ
    t = prim_wtype(fc, T)
    n = nbits(T)
    signed = f in (II.checked_sadd_int, II.checked_ssub_int, II.checked_smul_int)
    op = f in (II.checked_sadd_int, II.checked_uadd_int) ? "add" :
         f in (II.checked_ssub_int, II.checked_usub_int) ? "sub" : "mul"
    r = new_local!(fc, t)
    ovf = new_local!(fc, I32)
    if n < 64
        # compute exactly in i64 and check the range
        w = new_local!(fc, I64)
        for v in (a, b)
            signed ? push_signed!(fc, v) : push_val!(fc, v)
            t === I32 && emit!(fc.b, signed ? :i64_extend_i32_s : :i64_extend_i32_u)
        end
        emit!(fc.b, wop(I64, op))
        emit!(fc.b, :local_set, w)
        lo, hi = signed ? (-(Int64(1) << (n - 1)), (Int64(1) << (n - 1)) - 1) :
                          (Int64(0), (Int64(1) << n) - 1)
        emit!(fc.b, :local_get, w); emit!(fc.b, :i64_const, lo); emit!(fc.b, :i64_lt_s)
        emit!(fc.b, :local_get, w); emit!(fc.b, :i64_const, hi); emit!(fc.b, :i64_gt_s)
        emit!(fc.b, :i32_or)
        emit!(fc.b, :local_set, ovf)
        emit!(fc.b, :local_get, w)
        emit!(fc.b, :i32_wrap_i64)
        mask!(fc, T)
        emit!(fc.b, :local_set, r)
    else
        push_val!(fc, a); push_val!(fc, b)
        emit!(fc.b, wop(t, op))
        emit!(fc.b, :local_set, r)
        if op == "add" && signed
            # overflow iff both operands have the sign the result does not
            push_val!(fc, a); emit!(fc.b, :local_get, r); emit!(fc.b, :i64_xor)
            push_val!(fc, b); emit!(fc.b, :local_get, r); emit!(fc.b, :i64_xor)
            emit!(fc.b, :i64_and); emit!(fc.b, :i64_const, 0); emit!(fc.b, :i64_lt_s)
        elseif op == "add"
            emit!(fc.b, :local_get, r); push_val!(fc, a); emit!(fc.b, :i64_lt_u)
        elseif op == "sub" && signed
            push_val!(fc, a); push_val!(fc, b); emit!(fc.b, :i64_xor)
            push_val!(fc, a); emit!(fc.b, :local_get, r); emit!(fc.b, :i64_xor)
            emit!(fc.b, :i64_and); emit!(fc.b, :i64_const, 0); emit!(fc.b, :i64_lt_s)
        elseif op == "sub"
            push_val!(fc, a); push_val!(fc, b); emit!(fc.b, :i64_lt_u)
        else
            # a == 0: no overflow; signed a == -1: overflow iff b == typemin (where r / a
            # would trap); else overflow iff r / a != b
            push_val!(fc, a); emit!(fc.b, :i64_eqz)
            if!(fc.b, I32)
            emit!(fc.b, :i32_const, 0)
            else!(fc.b)
            if signed
                push_val!(fc, a); emit!(fc.b, :i64_const, -1); emit!(fc.b, :i64_eq)
                if!(fc.b, I32)
                push_val!(fc, b); emit!(fc.b, :i64_const, typemin(Int64)); emit!(fc.b, :i64_eq)
                else!(fc.b)
            end
            emit!(fc.b, :local_get, r); push_val!(fc, a)
            emit!(fc.b, signed ? :i64_div_s : :i64_div_u)
            push_val!(fc, b); emit!(fc.b, :i64_ne)
            signed && end!(fc.b)
            end!(fc.b)
        end
        emit!(fc.b, :local_set, ovf)
    end
    TT = Tuple{T,Bool}
    return CGVal(TT, Inline, LeafVal[r, ovf])
end

"""
    emit_checked_div!(fc, f, a, b) -> CGVal

A checked division: traps on division by zero, and on overflow (`typemin ÷ -1`) for the
signed ones, where Julia throws a `DivideError`.
"""
function emit_checked_div!(fc::FnCtx, f, a::CGVal, b::CGVal)
    T = a.typ
    t = prim_wtype(fc, T)
    signed = f === II.checked_sdiv_int || f === II.checked_srem_int
    push_val!(fc, b)
    emit!(fc.b, wop(t, "eqz"))
    if signed
        # typemin ÷ -1 (for narrow types, compare the sign-extended values)
        push_signed!(fc, b)
        emit!(fc.b, wop(t, "const"), -1)
        emit!(fc.b, wop(t, "eq"))
        push_signed!(fc, a)
        emit!(fc.b, wop(t, "const"), t === I64 ? typemin(Int64) : -(Int64(1) << (nbits(T) - 1)))
        emit!(fc.b, wop(t, "eq"))
        emit!(fc.b, :i32_and)
        if f === II.checked_srem_int
            # rem(typemin, -1) is 0: not an error, but Wasm's rem_s is defined for it
            emit!(fc.b, :drop)
            emit!(fc.b, :i32_const, 0)
        end
        emit!(fc.b, :i32_or)
    end
    if!(fc.b); unreachable!(fc.b); end!(fc.b)
    signed ? push_signed!(fc, a) : push_val!(fc, a)
    signed ? push_signed!(fc, b) : push_val!(fc, b)
    op = f === II.checked_sdiv_int ? "div_s" : f === II.checked_udiv_int ? "div_u" :
         f === II.checked_srem_int ? "rem_s" : "rem_u"
    emit!(fc.b, wop(t, op))
    mask!(fc, T)
    return pop_val!(fc, T)
end

