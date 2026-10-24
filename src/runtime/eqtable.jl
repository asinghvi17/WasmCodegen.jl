# Identity hash tables (`IdDict`, the C runtime's `jl_eqtable_*`): a `Memory{Any}` of keys and
# values in turn, open addressing by the key's `objectid` and `===`, as `iddict.c` does. A
# table built natively and serialized into the image is laid out by the same hash (`objectid`
# of an image object is its native one), so lookups at run time find its keys.

module EqTables

const HT_N_INLINE = 32

hash_size(a::Memory{Any}) = length(a) >> 1
max_probe(sz::Int) = sz <= 1024 ? 16 : sz >> 6
# the slot of the hash `hv` (0-based, of the key; the value is the next one)
h2index(hv::UInt, sz::Int) = (hv & (sz - 1)) % Int * 2

"""
    unset!(a::Memory{Any}, i)

Makes the element `i` of `a` undefined, as a deleted value of a table is. A primitive of the
code generator (a null reference); natively, a store of a null pointer.
"""
@noinline function unset!(a::Memory{Any}, i::Int)
    GC.@preserve a unsafe_store!(Ptr{Ptr{Cvoid}}(pointer(a, i)), C_NULL)
    return nothing
end

"The table with `key` set to `val` (grown if full), and whether the key is new."
function assign(a::Memory{Any}, @nospecialize(key), @nospecialize(val))
    sz = hash_size(a)
    if sz == 0
        a = Memory{Any}(undef, HT_N_INLINE)
        sz = hash_size(a)
    end
    maxprobe = max_probe(sz)
    hv = objectid(key)
    while true
        iter = 0
        index = h2index(hv, sz)
        n = 2sz
        orig = index
        empty_slot = -1
        while true
            if !isassigned(a, index + 1)
                empty_slot == -1 && (empty_slot = index)
                break
            end
            if key === a[index+1]
                if isassigned(a, index + 2)
                    a[index+2] = val
                    return a, false
                end
                # (a deleted entry: its key is `nothing`, which may be the key)
                empty_slot == -1 && (empty_slot = index)
            end
            empty_slot == -1 && !isassigned(a, index + 2) && (empty_slot = index)
            index = (index + 2) & (n - 1)
            iter += 1
            (iter <= maxprobe && index != orig) || break
        end
        if empty_slot != -1
            a[empty_slot+1] = key
            a[empty_slot+2] = val
            return a, true
        end
        # full: grow fast, rehash, and insert again
        len = length(a)
        newsz = len < HT_N_INLINE ? HT_N_INLINE :
                len >= (1 << 19) || len <= (1 << 8) ? len << 1 : len << 2
        a = rehash(a, newsz)
        sz = hash_size(a)
        maxprobe = max_probe(sz)
    end
end

function rehash(a::Memory{Any}, newsz::Int)
    b = Memory{Any}(undef, newsz)
    for i in 1:2:length(a)
        isassigned(a, i + 1) && (b = assign(b, a[i], a[i+1])[1])
    end
    return b
end

"The index (1-based) of the value of `key`, or 0."
function peek(a::Memory{Any}, @nospecialize(key))
    sz = hash_size(a)
    sz == 0 && return 0
    maxprobe = max_probe(sz)
    index = h2index(objectid(key), sz)
    n = 2sz
    orig = index
    iter = 0
    while true
        isassigned(a, index + 1) || return 0
        if key === a[index+1]
            isassigned(a, index + 2) && return index + 2
            key === nothing || return 0
        end
        index = (index + 2) & (n - 1)
        iter += 1
        (iter <= maxprobe && index != orig) || return 0
    end
end

# the C runtime's functions, as `ccall`s pass their arguments
put(h, @nospecialize(key), @nospecialize(val), inserted::Ptr{Cint}) =
    (r = assign(h::Memory{Any}, key, val); inserted == C_NULL || unsafe_store!(inserted, Cint(r[2])); r[1])
get(h, @nospecialize(key), @nospecialize(deflt)) =
    (i = peek(h::Memory{Any}, key); i == 0 ? deflt : (h::Memory{Any})[i])
function pop(h, @nospecialize(key), @nospecialize(deflt), found::Ptr{Cint})
    a = h::Memory{Any}
    i = peek(a, key)
    found == C_NULL || unsafe_store!(found, Cint(i != 0))
    i == 0 && return deflt
    val = a[i]
    a[i-1] = nothing
    unset!(a, i)
    return val
end
function nextind(t, i::Csize_t)
    a = t::Memory{Any}
    j = Int(i + (i & 1))
    while j < length(a) && !isassigned(a, j + 2)
        j += 2
    end
    return j >= length(a) ? typemax(Csize_t) : Csize_t(j)
end
rehash(t, newsz::Csize_t) = rehash(t::Memory{Any}, Int(newsz))

end
