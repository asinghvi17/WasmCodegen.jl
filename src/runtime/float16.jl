# Conversions of Float16, which Wasm does not have: its arithmetic is done in Float32 and
# rounded back (as LLVM does where the target has no half-precision arithmetic). These are
# compiler-rt's conversions (`__extendhfsf2`, `__truncsfhf2`, `__truncdfhf2`): exact
# widening, narrowing rounded to nearest even, NaNs made quiet with their payload kept.

"The Float32 of the bits `h` of a Float16 (exact)."
function f16_to_f32(h::UInt16)
    sign = UInt32(h & 0x8000) << 16
    e = (h >> 10) & 0x001f
    m = UInt32(h & 0x03ff)
    if e == 0x001f
        # infinity, or a NaN (quiet, with its payload)
        bits = m == 0 ? 0x7f800000 : 0x7fc00000 | (m << 13)
        return reinterpret(Float32, sign | bits)
    elseif e == 0
        # zero or subnormal: m × 2^-24, exact in Float32
        x = Float32(m) * reinterpret(Float32, 0x33800000)
        return reinterpret(Float32, sign | reinterpret(UInt32, x))
    end
    return reinterpret(Float32, sign | ((UInt32(e) + 0x00000070) << 23) | (m << 13))
end

"The bits of the Float16 nearest to `x` (ties to even)."
function f32_to_f16(x::Float32)
    f = reinterpret(UInt32, x)
    sign = UInt16((f & 0x80000000) >> 16)
    fe = f & 0x7f800000
    if fe >= 0x47800000
        m = f & 0x007fffff
        # a NaN (quiet, with the high bits of its payload); infinity or overflow
        fe == 0x7f800000 && m != 0 && return sign | 0x7e00 | UInt16((m >> 13) & 0x01ff)
        return sign | 0x7c00
    end
    if fe <= 0x38000000
        # a subnormal Float16, or zero
        fe < 0x33000000 && return sign
        e = fe >> 23
        m = 0x00800000 + (f & 0x007fffff)
        m >>= (113 - e)
        # round to nearest even: add half an ulp unless it is a tie with an even result (the
        # shift drops at most the low 11 bits of the significand)
        if (m & 0x00003fff) != 0x00001000 || (f & 0x000007ff) != 0
            m += 0x00001000
        end
        return sign | UInt16(m >> 13)
    end
    he = UInt16((fe - 0x38000000) >> 13)
    m = f & 0x007fffff
    (m & 0x00003fff) != 0x00001000 && (m += 0x00001000)
    # a carry out of the significand increments the exponent (to infinity at most)
    return sign | (UInt16(m >> 13) + he)
end

"The bits of the Float16 nearest to `x` (ties to even), rounded once."
function f64_to_f16(x::Float64)
    d = reinterpret(UInt64, x)
    sign = UInt16((d & 0x8000000000000000) >> 48)
    de = d & 0x7ff0000000000000
    if de >= 0x40f0000000000000
        m = d & 0x000fffffffffffff
        de == 0x7ff0000000000000 && m != 0 && return sign | 0x7e00 | UInt16((m >> 42) & 0x01ff)
        return sign | 0x7c00
    end
    if de <= 0x3f00000000000000
        de < 0x3e60000000000000 && return sign
        e = de >> 52
        m = (0x0010000000000000 + (d & 0x000fffffffffffff)) << (e - 998)
        (m & 0x003fffffffffffff) != 0x0010000000000000 && (m += 0x0010000000000000)
        return sign | UInt16(m >> 53)
    end
    he = UInt16((de - 0x3f00000000000000) >> 42)
    m = d & 0x000fffffffffffff
    (m & 0x000007ffffffffff) != 0x0000020000000000 && (m += 0x0000020000000000)
    return sign | (UInt16(m >> 42) + he)
end
