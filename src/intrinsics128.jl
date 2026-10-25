# 128-bit integer intrinsics: a 128-bit integer is two i64 leaves (low, high); the
# operations Wasm lacks are calls of the runtime (`runtime/int128.jl`).

is128(@nospecialize(T)) = T isa DataType && isprimitivetype(T) && sizeof(T) == 16

halves(v::CGVal) = (CGVal(UInt64, Inline, LeafVal[v.leaves[1]]), CGVal(UInt64, Inline, LeafVal[v.leaves[2]]))
as_type(@nospecialize(T), v::CGVal) = CGVal(T, Inline, v.leaves)

rt(fc::FnCtx, f, args::CGVal...) = call_runtime!(fc, f, CGVal[args...])

# a value of a primitive type as a UInt64 (its bits, zero- or sign-extended)
function to_u64!(fc::FnCtx, v::CGVal; signed::Bool=false)
    T = v.typ
    is128(T) && return halves(v)[1]
    t = prim_wtype(fc, T)
    signed ? push_signed!(fc, v) : push_val!(fc, v)
    t === I32 && emit!(fc.b, signed ? :i64_extend_i32_s : :i64_extend_i32_u)
    return pop_val!(fc, UInt64)
end

function emit_intrinsic128!(fc::FnCtx, f::Core.IntrinsicFunction, args::Vector{CGVal}, @nospecialize(typ))
    R = Runtime
    pairop = Dict(II.add_int => R.add128, II.sub_int => R.sub128, II.mul_int => R.mul128,
                  II.sdiv_int => R.sdiv128, II.udiv_int => R.udiv128,
                  II.srem_int => R.srem128, II.urem_int => R.urem128)
    cmpop = Dict(II.slt_int => R.slt128, II.sle_int => R.sle128, II.ult_int => R.ult128,
                 II.ule_int => R.ule128)
    if haskey(pairop, f)
        a, b = args
        return as_type(a.typ, rt(fc, pairop[f], halves(a)..., halves(b)...))
    elseif haskey(cmpop, f)
        a, b = args
        return rt(fc, cmpop[f], halves(a)..., halves(b)...)
    elseif f === II.neg_int
        a = args[1]
        return as_type(a.typ, rt(fc, R.neg128, halves(a)...))
    elseif f in (II.and_int, II.or_int, II.xor_int)
        a, b = args
        op = f === II.and_int ? :i64_and : f === II.or_int ? :i64_or : :i64_xor
        for k in 1:2
            push_leaf!(fc, a.leaves[k]); push_leaf!(fc, b.leaves[k]); emit!(fc.b, op)
        end
        return pop_val!(fc, a.typ)
    elseif f === II.not_int
        a = args[1]
        for k in 1:2
            push_leaf!(fc, a.leaves[k]); emit!(fc.b, :i64_const, -1); emit!(fc.b, :i64_xor)
        end
        return pop_val!(fc, a.typ)
    elseif f === II.eq_int || f === II.ne_int
        a, b = args
        for k in 1:2
            push_leaf!(fc, a.leaves[k]); push_leaf!(fc, b.leaves[k]); emit!(fc.b, :i64_eq)
        end
        emit!(fc.b, :i32_and)
        f === II.ne_int && emit!(fc.b, :i32_eqz)
        return pop_val!(fc, Bool)
    elseif f in (II.shl_int, II.lshr_int, II.ashr_int)
        x, n = args
        fn = f === II.shl_int ? R.shl128 : f === II.lshr_int ? R.lshr128 : R.ashr128
        if is128(n.typ)
            # a count with a high half is beyond 128
            lo, hi = halves(n)
            push_val!(fc, lo)
            emit!(fc.b, :i64_const, 128)
            push_val!(fc, hi)
            emit!(fc.b, :i64_eqz)
            emit!(fc.b, :select)
            cnt = pop_val!(fc, UInt64)
        else
            cnt = to_u64!(fc, n)
        end
        # (a narrower value by a 128-bit count: shifted as such)
        is128(x.typ) || return emit_intrinsic!(fc, f, Any[x, cnt], typ)
        return as_type(x.typ, rt(fc, fn, halves(x)..., cnt))
    elseif f === II.sext_int || f === II.zext_int
        R128 = constant_value(args[1]); x = args[2]
        is128(x.typ) && return as_type(R128, x)
        lo = to_u64!(fc, x; signed=f === II.sext_int)
        if f === II.sext_int
            push_val!(fc, lo)
            emit!(fc.b, :i64_const, 63)
            emit!(fc.b, :i64_shr_s)
            hi = pop_val!(fc, UInt64)
        else
            hi = const_value(fc, UInt64(0))
        end
        return CGVal(R128, Inline, LeafVal[lo.leaves[1], hi.leaves[1]])
    elseif f === II.trunc_int
        Rt = constant_value(args[1]); x = args[2]
        is128(Rt) && return as_type(Rt, x)
        lo = halves(x)[1]
        prim_wtype(fc, Rt) === I64 && return CGVal(Rt, Inline, lo.leaves)
        push_val!(fc, lo)
        emit!(fc.b, :i32_wrap_i64)
        mask!(fc, Rt)
        return pop_val!(fc, Rt)
    elseif f === II.bitcast
        Rt = constant_value(args[1]); x = args[2]
        is128(Rt) && is128(x.typ) && return as_type(Rt, x)
    elseif f in (II.ctlz_int, II.cttz_int, II.ctpop_int)
        x = args[1]
        fn = f === II.ctlz_int ? R.ctlz128 : f === II.cttz_int ? R.cttz128 : R.ctpop128
        c = rt(fc, fn, halves(x)...)
        return CGVal(x.typ, Inline, LeafVal[c.leaves[1], Inst(:i64_const, 0)])
    elseif f === II.bswap_int
        x = args[1]
        return as_type(x.typ, rt(fc, R.bswap128, halves(x)...))
    elseif f === II.flipsign_int
        x, y = args
        neg = as_type(x.typ, rt(fc, R.neg128, halves(x)...))
        ylo, yhi = is128(y.typ) ? halves(y) : (nothing, to_u64!(fc, y; signed=true))
        c = new_local!(fc, I32)
        push_val!(fc, yhi); emit!(fc.b, :i64_const, 0); emit!(fc.b, :i64_lt_s)
        emit!(fc.b, :local_set, c)
        for k in 1:2
            push_leaf!(fc, neg.leaves[k]); push_leaf!(fc, x.leaves[k]); emit!(fc.b, :local_get, c)
            emit!(fc.b, :select)
        end
        return pop_val!(fc, x.typ)
    elseif f in (II.checked_sadd_int, II.checked_uadd_int, II.checked_ssub_int,
                 II.checked_usub_int, II.checked_smul_int, II.checked_umul_int)
        a, b = args
        fn = Dict(II.checked_sadd_int => R.checked_sadd128, II.checked_uadd_int => R.checked_uadd128,
                  II.checked_ssub_int => R.checked_ssub128, II.checked_usub_int => R.checked_usub128,
                  II.checked_smul_int => R.checked_smul128, II.checked_umul_int => R.checked_umul128)[f]
        r = rt(fc, fn, halves(a)..., halves(b)...)
        return CGVal(Tuple{a.typ,Bool}, Inline, r.leaves)
    elseif f in (II.checked_sdiv_int, II.checked_udiv_int, II.checked_srem_int, II.checked_urem_int)
        a, b = args
        # division by zero traps (Julia throws DivideError); typemin ÷ -1 too, for div
        push_leaf!(fc, b.leaves[1]); push_leaf!(fc, b.leaves[2]); emit!(fc.b, :i64_or)
        emit!(fc.b, :i64_eqz)
        if!(fc.b); throw_error!(fc, Runtime.throw_divide_error); end!(fc.b)
        if f === II.checked_sdiv_int
            push_leaf!(fc, b.leaves[1]); emit!(fc.b, :i64_const, -1); emit!(fc.b, :i64_eq)
            push_leaf!(fc, b.leaves[2]); emit!(fc.b, :i64_const, -1); emit!(fc.b, :i64_eq)
            emit!(fc.b, :i32_and)
            push_leaf!(fc, a.leaves[1]); emit!(fc.b, :i64_eqz); emit!(fc.b, :i32_and)
            push_leaf!(fc, a.leaves[2]); emit!(fc.b, :i64_const, typemin(Int64)); emit!(fc.b, :i64_eq)
            emit!(fc.b, :i32_and)
            if!(fc.b); throw_error!(fc, Runtime.throw_divide_error); end!(fc.b)
        end
        fn = f === II.checked_sdiv_int ? R.sdiv128 : f === II.checked_udiv_int ? R.udiv128 :
             f === II.checked_srem_int ? R.srem128 : R.urem128
        return as_type(a.typ, rt(fc, fn, halves(a)..., halves(b)...))
    end
    unsupported("the intrinsic ", f, " on 128-bit integers")
end
