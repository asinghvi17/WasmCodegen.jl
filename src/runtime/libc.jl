# Functions of the C library that Base calls for computations on bytes, done here (with
# `pointers.jl`'s memchr, memcmp, ...): `memrchr`, `strcmp`.

"`memrchr(p, c, n)`: the last of the `n` bytes at `p` equal to `c`, or a null pointer."
function ptr_memrchr(p::Ptr{UInt8}, c::Int32, n::UInt)
    b = c % UInt8
    i = n
    while i > 0
        unsafe_load(p, i) == b && return p + (i - 1)
        i -= 1
    end
    return Ptr{UInt8}(0)
end

"`strcmp(a, b)`: the sign of the first difference of the NUL-terminated bytes at `a` and `b`."
function ptr_strcmp(a::Ptr{UInt8}, b::Ptr{UInt8})
    i = UInt(1)
    while true
        x, y = unsafe_load(a, i), unsafe_load(b, i)
        x == y || return x < y ? Int32(-1) : Int32(1)
        x == 0x00 && return Int32(0)
        i += 1
    end
end
ptr_strcmp(a::Cstring, b::Cstring) = ptr_strcmp(convert(Ptr{UInt8}, a), convert(Ptr{UInt8}, b))
