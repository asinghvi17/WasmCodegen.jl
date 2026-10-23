# 128-bit integer arithmetic on (low, high) pairs of UInt64s: what Wasm lacks, written in
# Julia with 64-bit operations only, and compiled into the module where 128-bit intrinsics
# are used (a 128-bit integer is its two 64-bit halves, see `layout.jl`).

const U64 = UInt64

@inline function add128(al::U64, ah::U64, bl::U64, bh::U64)
    lo = al + bl
    return (lo, ah + bh + U64(lo < al))
end

@inline function sub128(al::U64, ah::U64, bl::U64, bh::U64)
    return (al - bl, ah - bh - U64(al < bl))
end

# the high half of the 128-bit product of two UInt64s (32-bit halves)
@inline function mulhi64(a::U64, b::U64)
    a0, a1 = a & 0xffffffff, a >> 32
    b0, b1 = b & 0xffffffff, b >> 32
    p00, p01, p10, p11 = a0 * b0, a0 * b1, a1 * b0, a1 * b1
    mid = (p00 >> 32) + (p01 & 0xffffffff) + (p10 & 0xffffffff)
    return p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32)
end

@inline function mul128(al::U64, ah::U64, bl::U64, bh::U64)
    return (al * bl, mulhi64(al, bl) + al * bh + ah * bl)
end

@inline neg128(al::U64, ah::U64) = sub128(U64(0), U64(0), al, ah)

@inline ult128(al::U64, ah::U64, bl::U64, bh::U64) = (ah < bh) | ((ah == bh) & (al < bl))
@inline ule128(al::U64, ah::U64, bl::U64, bh::U64) = (ah < bh) | ((ah == bh) & (al <= bl))
@inline slt128(al::U64, ah::U64, bl::U64, bh::U64) =
    (reinterpret(Int64, ah) < reinterpret(Int64, bh)) | ((ah == bh) & (al < bl))
@inline sle128(al::U64, ah::U64, bl::U64, bh::U64) =
    (reinterpret(Int64, ah) < reinterpret(Int64, bh)) | ((ah == bh) & (al <= bl))

# shifts by `n` (an unsigned count; 128 or more shifts everything out)
@inline function shl128(al::U64, ah::U64, n::U64)
    n >= 128 && return (U64(0), U64(0))
    n >= 64 && return (U64(0), al << (n - 64))
    n == 0 && return (al, ah)
    return (al << n, (ah << n) | (al >> (64 - n)))
end

@inline function lshr128(al::U64, ah::U64, n::U64)
    n >= 128 && return (U64(0), U64(0))
    n >= 64 && return (ah >> (n - 64), U64(0))
    n == 0 && return (al, ah)
    return ((al >> n) | (ah << (64 - n)), ah >> n)
end

@inline function ashr128(al::U64, ah::U64, n::U64)
    sign = reinterpret(U64, reinterpret(Int64, ah) >> 63)
    n >= 128 && return (sign, sign)
    n >= 64 && return (reinterpret(U64, reinterpret(Int64, ah) >> (n - 64)), sign)
    n == 0 && return (al, ah)
    return ((al >> n) | (ah << (64 - n)), reinterpret(U64, reinterpret(Int64, ah) >> n))
end

@inline ctlz128(al::U64, ah::U64) = ah == 0 ? U64(64 + leading_zeros(al)) : U64(leading_zeros(ah))
@inline cttz128(al::U64, ah::U64) = al == 0 ? U64(64 + trailing_zeros(ah)) : U64(trailing_zeros(al))
@inline ctpop128(al::U64, ah::U64) = U64(count_ones(al) + count_ones(ah))
@inline bswap128(al::U64, ah::U64) = (bswap(ah), bswap(al))

# unsigned division with remainder, by shift and subtract (the divisor is not zero)
function udivrem128(al::U64, ah::U64, bl::U64, bh::U64)
    ql, qh = U64(0), U64(0)
    rl, rh = U64(0), U64(0)
    for i in 127:-1:0
        # r = r << 1 | bit i of a
        rl, rh = shl128(rl, rh, U64(1))
        bit = i >= 64 ? (ah >> (i - 64)) & 1 : (al >> i) & 1
        rl |= bit
        if !ult128(rl, rh, bl, bh)
            rl, rh = sub128(rl, rh, bl, bh)
            if i >= 64
                qh |= U64(1) << (i - 64)
            else
                ql |= U64(1) << i
            end
        end
    end
    return (ql, qh, rl, rh)
end

udiv128(al::U64, ah::U64, bl::U64, bh::U64) = (q = udivrem128(al, ah, bl, bh); (q[1], q[2]))
urem128(al::U64, ah::U64, bl::U64, bh::U64) = (q = udivrem128(al, ah, bl, bh); (q[3], q[4]))

isneg128(ah::U64) = reinterpret(Int64, ah) < 0
abs128(al::U64, ah::U64) = isneg128(ah) ? neg128(al, ah) : (al, ah)

function sdiv128(al::U64, ah::U64, bl::U64, bh::U64)
    ql, qh = udiv128(abs128(al, ah)..., abs128(bl, bh)...)
    return isneg128(ah) != isneg128(bh) ? neg128(ql, qh) : (ql, qh)
end

function srem128(al::U64, ah::U64, bl::U64, bh::U64)
    rl, rh = urem128(abs128(al, ah)..., abs128(bl, bh)...)
    return isneg128(ah) ? neg128(rl, rh) : (rl, rh)
end

# checked arithmetic: the result and whether it overflowed
function checked_sadd128(al::U64, ah::U64, bl::U64, bh::U64)
    rl, rh = add128(al, ah, bl, bh)
    return (rl, rh, isneg128((ah ⊻ rh) & (bh ⊻ rh)))
end
function checked_uadd128(al::U64, ah::U64, bl::U64, bh::U64)
    rl, rh = add128(al, ah, bl, bh)
    return (rl, rh, ult128(rl, rh, al, ah))
end
function checked_ssub128(al::U64, ah::U64, bl::U64, bh::U64)
    rl, rh = sub128(al, ah, bl, bh)
    return (rl, rh, isneg128((ah ⊻ bh) & (ah ⊻ rh)))
end
function checked_usub128(al::U64, ah::U64, bl::U64, bh::U64)
    rl, rh = sub128(al, ah, bl, bh)
    return (rl, rh, ult128(al, ah, bl, bh))
end
function checked_umul128(al::U64, ah::U64, bl::U64, bh::U64)
    rl, rh = mul128(al, ah, bl, bh)
    overflow = (al != 0 || ah != 0) &&
               (q = udiv128(rl, rh, al, ah); q[1] != bl || q[2] != bh)
    return (rl, rh, overflow)
end
function checked_smul128(al::U64, ah::U64, bl::U64, bh::U64)
    rl, rh = mul128(al, ah, bl, bh)
    (al == 0 && ah == 0) && return (rl, rh, false)
    # typemin * -1
    if al == typemax(U64) && ah == typemax(U64) && bl == 0 && bh == U64(1) << 63
        return (rl, rh, true)
    end
    ql, qh = sdiv128(rl, rh, al, ah)
    return (rl, rh, ql != bl || qh != bh)
end
