# Functions of Julia's C runtime (libjulia) that Base calls and that are computations, done
# here as natively (see `runtime_ccalls.jl`).

## IdSet (`Base.IdSet`): src/idset.c over src/smallintset.c

"""
The C runtime's `jl_idset_*`: an `IdSet`'s keys are a `Memory{Any}` filled from the front (a
deleted key leaves a hole), and its index a hash table of small integers (`idxs`: a
`Memory{UInt8}`, `{UInt16}` or `{UInt32}`) holding key positions + 1, 0 for an empty slot and
all ones for a deleted one, by open addressing on the key's `objectid` and `===`. As natively,
so that an `IdSet` built at compile time (with the native `objectid`s of the image's
objects) is found at run time and iterates in the same order.
"""
module IdSets

import ..EqTables: unset!

const HT_N_INLINE = 32
max_probe(sz::Int) = sz <= 1024 ? 16 : sz >> 6
h2index(hv::UInt, sz::Int) = (hv & (sz - 1)) % Int

# `jl_intref`: the value of slot `i` (0-based), a deleted one as empty (0)
intref(a::Memory{T}, i::Int) where {T} = (v = a[i+1]; v == typemax(T) ? 0 : Int(v))
# `jl_intref_acquire`: a deleted one as -1
intref_acquire(a::Memory{T}, i::Int) where {T} = (v = a[i+1]; v == typemax(T) ? -1 : Int(v))
max_int(::Memory{T}) where {T} = Int(typemax(T))

function alloc_int(np::Int, len::Int)
    np < 0xff && return fill!(Memory{UInt8}(undef, len), 0x00)
    np < 0xffff && return fill!(Memory{UInt16}(undef, len), 0x0000)
    return fill!(Memory{UInt32}(undef, len), 0x00000000)
end

# `idset_hash`: the objectid of the key at position `idx` (0-based), 0 for none
function key_hash(idx::Int, keys::Memory{Any})
    idx < length(keys) && isassigned(keys, idx + 1) || return UInt(0)
    return objectid(keys[idx+1])
end

function lookup(idxs::Memory{T}, keys::Memory{Any}, @nospecialize(key), hv::UInt, pop::Bool) where {T}
    sz = length(idxs)
    sz == 0 && return -1
    maxprobe = max_probe(sz)
    index = h2index(hv, sz)
    orig = index
    iter = 0
    while true
        val1 = intref_acquire(idxs, index)
        val1 == 0 && return -1
        if val1 != -1 && val1 - 1 < length(keys) && isassigned(keys, val1) && keys[val1] === key
            pop && (idxs[index+1] = typemax(T))
            return val1 - 1
        end
        index = (index + 1) & (sz - 1)
        iter += 1
        (iter <= maxprobe && index != orig) || return -1
    end
end

# `smallintset_insert_`: whether `val1` found an empty slot
function insert_slot!(a::Memory{T}, hv::UInt, val1::Int) where {T}
    sz = length(a)
    sz <= 1 && return false
    index = h2index(hv, sz)
    orig = index
    maxprobe = max_probe(sz)
    iter = 0
    while true
        if intref(a, index) == 0
            a[index+1] = val1 % T
            return true
        end
        index = (index + 1) & (sz - 1)
        iter += 1
        (iter <= maxprobe && index != orig) || return false
    end
end

function rehash(a::Memory, keys::Memory{Any}, newsz::Int, np::Int)
    sz = length(a)
    for i in 0:sz-1
        np = max(np, intref(a, i))
    end
    while true
        newa = alloc_int(np + 1, newsz)
        ok = true
        for i in 0:sz-1
            val1 = intref(a, i)
            if val1 != 0 && !insert_slot!(newa, key_hash(val1 - 1, keys), val1)
                ok = false
                break
            end
        end
        ok && return newa
        newsz <<= 1
    end
end

# `jl_smallintset_insert`: the table with position `val` added (a new one when it grows)
function insert(a::Memory, keys::Memory{Any}, val::Int)
    if val + 1 >= max_int(a)
        a = rehash(a, keys, length(a), val + 1)
    end
    while true
        insert_slot!(a, key_hash(val, keys), val + 1) && return a
        sz = length(a)
        newsz = sz < HT_N_INLINE ? HT_N_INLINE :
                sz >= (1 << 19) || sz <= (1 << 8) ? sz << 1 : sz << 2
        a = rehash(a, keys, newsz, 0)
    end
end

# the index table of the `Union` field `idxs` as one of its types (`f(idxs::Memory{T})`)
@inline function with_idxs(f, idxs)
    idxs isa Memory{UInt8} && return f(idxs)
    idxs isa Memory{UInt16} && return f(idxs)
    return f(idxs::Memory{UInt32})
end

# the C functions, as `ccall`s pass their arguments (`Any`s; positions are 0-based)
# (by the index's width, without a closure capturing `key`: inference may specialize one on
# the key's type, which is not known)
function lookup_any(idxs, keys::Memory{Any}, @nospecialize(key), pop::Bool)
    hv = objectid(key)
    idxs isa Memory{UInt8} && return lookup(idxs, keys, key, hv, pop)
    idxs isa Memory{UInt16} && return lookup(idxs, keys, key, hv, pop)
    return lookup(idxs::Memory{UInt32}, keys, key, hv, pop)
end

peek_bp(keys, idxs, @nospecialize(key)) = lookup_any(idxs, keys::Memory{Any}, key, false)

function pop(keys, idxs, @nospecialize(key))
    k = keys::Memory{Any}
    idx = lookup_any(idxs, k, key, true)
    idx != -1 && unset!(k, idx + 1)
    return idx
end

# `idset_compact`: the keys moved to the front; their number, negated if any moved
function compact!(keys::Memory{Any})
    moved = false
    j = 0
    for i in 0:length(keys)-1
        if isassigned(keys, i + 1)
            if i != j
                moved = true
                keys[j+1] = keys[i+1]
                unset!(keys, i + 1)
            end
            j += 1
        end
    end
    return moved ? -j : j
end

function put_key(keys, @nospecialize(key), newidx::Ptr{Int})
    k = keys::Memory{Any}
    l = length(k)
    i = l
    while i > 0 && !isassigned(k, i)
        i -= 1
    end
    unsafe_store!(newidx, i)
    if i == l
        i = compact!(k)
        if i < 0
            unsafe_store!(newidx, i - 1)
            i = -i
        end
        if i >= l ÷ 3 * 2
            nl = l < 4 ? 4 : (l * 3) >> 1
            nk = Memory{Any}(undef, nl)
            for j in 1:i
                nk[j] = k[j]
            end
            k = nk
        end
    end
    k[i+1] = key
    return k
end

function put_idx(keys, idxs, idx::Int)
    k = keys::Memory{Any}
    if idx < 0
        # a full rehash, after the keys were compacted
        with_idxs(t -> fill!(t, zero(eltype(t))), idxs)
        new = idxs
        for i in 0:-idx-1
            isassigned(k, i + 1) && (new = insert(new::Memory, k, i))
        end
        return new
    end
    return insert(idxs::Memory, k, idx)
end

end
