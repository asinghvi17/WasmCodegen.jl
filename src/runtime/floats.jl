# Parsing floating-point numbers, for what Julia's C runtime does with the C library's
# `strtod`/`strtof` (`jl_strtod_c`, `jl_strtof_c`), and `errno`, which reports their range
# errors (`jl_set_errno`, `jl_errno`). The conversion is Parsers.jl's, which is correctly
# rounded for every input without C or big floats (Clinger's fast path, Eisel and Lemire's
# algorithm, then exact limb arithmetic); this finds the extent of the number as `strtod`
# does, and reports its range errors in `errno`.

module Floats

import Parsers

## errno

const ERRNO = Ref{Int32}(0)
set_errno(e::Int32) = (ERRNO[] = e; nothing)
get_errno() = ERRNO[]
const ERANGE = Int32(Base.Libc.ERANGE)

## parsing

isdigit_(b) = UInt8('0') <= b <= UInt8('9')
isletter_(b) = UInt8('a') <= lower(b) <= UInt8('z')

# the bytes i:j-1 as `strtoull(s, 0)` reads them when they are a whole number (0x hex,
# leading 0 octal, decimal), else 0
function c_unsigned(at, i::Int, j::Int)
    base, k = 10, i
    if at(k) == UInt8('0') && lower(at(k + 1)) == UInt8('x')
        base, k = 16, k + 2
    elseif at(k) == UInt8('0')
        base = 8
    end
    k >= j && return UInt64(0)
    v = UInt64(0)
    while k < j
        b = lower(at(k))
        d = isdigit_(b) ? Int(b - UInt8('0')) : UInt8('a') <= b <= UInt8('f') ? Int(b - UInt8('a')) + 10 : 99
        d < base || return UInt64(0)
        v = v * base + d
        k += 1
    end
    return v
end
ishex(b) = isdigit_(b) || UInt8('a') <= b <= UInt8('f') || UInt8('A') <= b <= UInt8('F')
lower(b) = UInt8('A') <= b <= UInt8('Z') ? b + 0x20 : b

"""
    strto(T, p, endptr) -> T

`strtod` (T = Float64) or `strtof` (T = Float32) of the NUL-terminated bytes at `p`: the
longest prefix that is a number (after white space), with `endptr` set past it; `errno`
is set to ERANGE when the value overflows to infinity, or is not zero but rounds to zero
or to a subnormal number. (The C library does not set it for a subnormal number given
exactly, as `0x1p-1074`; Parsers does not say whether a result is exact.)
"""
function strto(::Type{T}, p::Ptr{UInt8}, endptr::Ptr{Ptr{UInt8}}) where {T}
    x, n = scan_float(T, i -> unsafe_load(p, i + 1))
    unsafe_store!(endptr, p + n)
    return x
end

"""
    scan_float(T, at) -> (x, n)

The number at the start of the bytes `at(0)`, `at(1)`, ... (ending in a NUL), as `strtod`
reads it, and the number of bytes it takes (0 if there is none); `errno` as for `strto`.
"""
function scan_float(::Type{T}, at::F) where {T,F}
    i = 0
    while at(i) == UInt8(' ') || UInt8('\t') <= at(i) <= UInt8('\r')
        i += 1
    end
    start = i
    (at(i) == UInt8('+') || at(i) == UInt8('-')) && (i += 1)
    hex = false
    payload = nothing
    if lower(at(i)) == UInt8('i') && lower(at(i + 1)) == UInt8('n') && lower(at(i + 2)) == UInt8('f')
        i += 3
        n = 0
        for c in (UInt8('i'), UInt8('n'), UInt8('i'), UInt8('t'), UInt8('y'))
            lower(at(i + n)) == c || break
            n += 1
        end
        n == 5 && (i += 5)
    elseif lower(at(i)) == UInt8('n') && lower(at(i + 1)) == UInt8('a') && lower(at(i + 2)) == UInt8('n')
        i += 3
        # nan(chars): the payload, the chars as an unsigned C integer (0 if they are not one)
        if at(i) == UInt8('(')
            j = i + 1
            while isletter_(at(j)) || isdigit_(at(j)) || at(j) == UInt8('_'); j += 1; end
            if at(j) == UInt8(')')
                payload = c_unsigned(at, i + 1, j)
                i = j + 1
            end
        end
    elseif at(i) == UInt8('0') && lower(at(i + 1)) == UInt8('x') &&
           (ishex(at(i + 2)) || (at(i + 2) == UInt8('.') && ishex(at(i + 3))))
        # hexadecimal: digits, a point, digits, then p and a binary exponent
        hex = true
        i += 2
        while ishex(at(i)); i += 1; end
        if at(i) == UInt8('.')
            i += 1
            while ishex(at(i)); i += 1; end
        end
        i = exponent_end(at, i, UInt8('p'))
    elseif isdigit_(at(i)) || (at(i) == UInt8('.') && isdigit_(at(i + 1)))
        while isdigit_(at(i)); i += 1; end
        if at(i) == UInt8('.')
            i += 1
            while isdigit_(at(i)); i += 1; end
        end
        i = exponent_end(at, i, UInt8('e'))
    else
        # no number: nothing consumed
        return T(0), 0
    end
    buf = Vector{UInt8}(undef, i - start)
    for k in eachindex(buf)
        buf[k] = at(start + k - 1)
    end
    if payload !== nothing
        # a quiet NaN of that payload, with the sign
        U = T === Float64 ? UInt64 : UInt32
        bits = reinterpret(U, T(NaN)) | (U(payload) & (U(1) << (8sizeof(T) - Base.exponent_bits(T) - 2) - U(1)))
        at(start) == UInt8('-') && (bits |= Base.sign_mask(T))
        return reinterpret(T, bits), i
    end
    x, rc = hex ? Parsers._parsehexfloat(T, buf, 1, length(buf)) :
                  Parsers.parsefloat(T, buf, 1, length(buf))
    if rc == Parsers.RC_OVERFLOW || rc == Parsers.RC_UNDERFLOW ||
       (x != 0 && abs(x) < floatmin(T))
        ERRNO[] = ERANGE
    end
    return x, i
end

# past an exponent (`e` or `p`, a sign, digits) at offset i, if there is one
function exponent_end(at, i::Int, letter::UInt8)
    lower(at(i)) == letter || return i
    j = i + 1
    (at(j) == UInt8('+') || at(j) == UInt8('-')) && (j += 1)
    isdigit_(at(j)) || return i
    while isdigit_(at(j)); j += 1; end
    return j
end

strtod(p::Ptr{UInt8}, endptr::Ptr{Ptr{UInt8}}) = strto(Float64, p, endptr)
strtof(p::Ptr{UInt8}, endptr::Ptr{Ptr{UInt8}}) = strto(Float32, p, endptr)

iscspace(b::UInt8) = b == UInt8(' ') || UInt8('\t') <= b <= UInt8('\r')

"""
    try_substrto(T, str, offset, len) -> (hasvalue, x)

`jl_try_substrtod` (T = Float64) or `jl_try_substrtof` (Float32): the number that the `len`
bytes at `str + offset` are, with white space around it, if they are one in range.
"""
function try_substrto(::Type{T}, str::Ptr{UInt8}, offset::UInt, len::UInt) where {T}
    p = str + offset
    n = Int(len)
    ERRNO[] = 0
    x, i = scan_float(T, k -> k < n ? unsafe_load(p, k + 1) : 0x00)
    (ERRNO[] == ERANGE && (x == 0 || isinf(x))) && return (false, x)
    i == 0 && return (false, x)
    for k in i:n-1
        iscspace(unsafe_load(p, k + 1)) || return (false, x)
    end
    return (true, x)
end
try_substrtod(str::Ptr{UInt8}, offset::UInt, len::UInt) = try_substrto(Float64, str, offset, len)
try_substrtof(str::Ptr{UInt8}, offset::UInt, len::UInt) = try_substrto(Float32, str, offset, len)

end
