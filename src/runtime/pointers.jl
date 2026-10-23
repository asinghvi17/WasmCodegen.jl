# Copies and fills of bytes through pointers whose origin the code generator does not know
# (see `pointers.jl`): its loads and stores of bytes find the memory from the pointer's
# owner at run time.

"`memmove(dst, src, n)`: the `n` bytes at `src` copied to `dst`, which may overlap."
function ptr_memmove(dst::Ptr{UInt8}, src::Ptr{UInt8}, n::UInt)
    if dst > src
        i = n
        while i > 0
            unsafe_store!(dst, unsafe_load(src, i), i)
            i -= 1
        end
    else
        i = UInt(1)
        while i <= n
            unsafe_store!(dst, unsafe_load(src, i), i)
            i += 1
        end
    end
    return dst
end

"`memset(p, b, n)`: the `n` bytes at `p` set to `b`."
function ptr_memset(p::Ptr{UInt8}, b::UInt8, n::UInt)
    i = UInt(1)
    while i <= n
        unsafe_store!(p, b, i)
        i += 1
    end
    return p
end

"`memcmp(a, b, n)`: the sign of the first difference of the `n` bytes at `a` and `b`."
function ptr_memcmp(a::Ptr{UInt8}, b::Ptr{UInt8}, n::UInt)
    i = UInt(1)
    while i <= n
        x, y = unsafe_load(a, i), unsafe_load(b, i)
        x == y || return x < y ? Int32(-1) : Int32(1)
        i += 1
    end
    return Int32(0)
end

"`memchr(p, c, n)`: the first of the `n` bytes at `p` equal to `c`, or a null pointer."
function ptr_memchr(p::Ptr{UInt8}, c::Int32, n::UInt)
    b = c % UInt8
    i = UInt(1)
    while i <= n
        unsafe_load(p, i) == b && return p + (i - 1)
        i += 1
    end
    return Ptr{UInt8}(0)
end
