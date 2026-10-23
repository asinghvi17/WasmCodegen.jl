# Unicode properties of characters, for what Base and the parser ask libutf8proc and libjulia
# (`utf8proc_category`, `jl_id_char`, `jl_id_start_char`, grapheme breaks). The tables are
# computed from the native libraries when WasmCodegen is compiled, as runs of code points
# with one value, so they are the ones of the Julia that compiles the program; a module
# that uses one carries it as data.

module UnicodeData

# the runs of `f` over all code points: (first code point of each run, value of the run)
function runs(f)
    starts = UInt32[]
    values = Int8[]
    prev = typemin(Int)
    for c in UInt32(0):UInt32(0x10ffff)
        v = Int(f(c))
        if v != prev
            push!(starts, c)
            push!(values, v)
            prev = v
        end
    end
    return (starts, values)
end

# the value of the run holding `c`, or `invalid` past the last code point
function lookup(table::Tuple{Vector{UInt32},Vector{Int8}}, c::UInt32, invalid::Int8)
    c > 0x10ffff && return invalid
    starts, values = table
    return @inbounds values[searchsortedlast(starts, c)]
end

native_category(c) = ccall(:utf8proc_category, Cint, (UInt32,), c)
native_id_char(c) = ccall(:jl_id_char, Cint, (UInt32,), c)
native_id_start_char(c) = ccall(:jl_id_start_char, Cint, (UInt32,), c)

# a character's grapheme bound class and Indic conjunct break class, read back from
# utf8proc's own state: after a consonant (whose bound class is Other), the state of
# `grapheme_break_stateful` holds the next character's two classes
function native_break_classes(c)
    state = Ref{Int32}(0)
    ccall(:utf8proc_grapheme_break_stateful, Bool, (UInt32, UInt32, Ref{Int32}), 0x0915, c, state)
    return state[]
end

const CATEGORY = runs(native_category)
const ID_CHAR = runs(native_id_char)
const ID_START_CHAR = runs(native_id_start_char)
const BOUNDCLASS = runs(c -> native_break_classes(c) & 0xff)
const INDIC_CONJUNCT = runs(c -> native_break_classes(c) >> 8)
const CATEGORY_INVALID = Int8(native_category(0x110000))
const ID_CHAR_INVALID = Int8(native_id_char(0x110000))
const ID_START_CHAR_INVALID = Int8(native_id_start_char(0x110000))
const BOUNDCLASS_INVALID = Int8(native_break_classes(0x110000) & 0xff)
const INDIC_CONJUNCT_INVALID = Int8(native_break_classes(0x110000) >> 8)

"`utf8proc_category(c)`."
category(c::UInt32) = Int32(lookup(CATEGORY, c, CATEGORY_INVALID))
"`jl_id_char(c)`: whether `c` may continue an identifier."
id_char(c::UInt32) = Int32(lookup(ID_CHAR, c, ID_CHAR_INVALID))
"`jl_id_start_char(c)`: whether `c` may start an identifier."
id_start_char(c::UInt32) = Int32(lookup(ID_START_CHAR, c, ID_START_CHAR_INVALID))

# utf8proc's bound classes and Indic conjunct break classes
const START, OTHER, CR, CONTROL, EXTEND, L, V, T, LV, LVT = 0, 1, 2, 4, 5, 6, 7, 8, 9, 10
const LF, REGIONAL_INDICATOR, SPACINGMARK, PREPEND, ZWJ = 3, 11, 12, 13, 14
const EXTENDED_PICTOGRAPHIC, E_ZWG = 19, 20
const ICB_NONE, ICB_LINKER, ICB_CONSONANT, ICB_EXTEND = 0, 1, 2, 3

# utf8proc's `grapheme_break_simple`: rules GB1 to GB999 on two bound classes
function grapheme_break_simple(lbc::Int, tbc::Int)
    lbc == START && return true                                          # GB1
    lbc == CR && tbc == LF && return false                               # GB3
    CR <= lbc <= CONTROL && return true                                  # GB4
    CR <= tbc <= CONTROL && return true                                  # GB5
    lbc == L && (tbc == L || tbc == V || tbc == LV || tbc == LVT) && return false  # GB6
    (lbc == LV || lbc == V) && (tbc == V || tbc == T) && return false    # GB7
    (lbc == LVT || lbc == T) && tbc == T && return false                 # GB8
    (tbc == EXTEND || tbc == ZWJ || tbc == SPACINGMARK || lbc == PREPEND) && return false  # GB9, 9a, 9b
    lbc == E_ZWG && tbc == EXTENDED_PICTOGRAPHIC && return false         # GB11
    lbc == REGIONAL_INDICATOR && tbc == REGIONAL_INDICATOR && return false  # GB12, 13
    return true                                                          # GB999
end

"""
    grapheme_break_stateful(c1, c2, state::Ptr{Int32}) -> Bool

`utf8proc_grapheme_break_stateful`: whether a grapheme break is allowed between `c1` and
`c2`, given and updating the state of the rules that look further back.
"""
function grapheme_break_stateful(c1::UInt32, c2::UInt32, state::Ptr{Int32})
    lbc = Int(lookup(BOUNDCLASS, c1, BOUNDCLASS_INVALID))
    tbc = Int(lookup(BOUNDCLASS, c2, BOUNDCLASS_INVALID))
    licb = Int(lookup(INDIC_CONJUNCT, c1, INDIC_CONJUNCT_INVALID))
    ticb = Int(lookup(INDIC_CONJUNCT, c2, INDIC_CONJUNCT_INVALID))
    s = Int(unsafe_load(state))
    if s == 0
        state_bc = lbc
        state_icb = licb == ICB_CONSONANT ? licb : ICB_NONE
    else
        state_bc = s & 0xff
        state_icb = s >> 8
    end
    break_permitted = grapheme_break_simple(state_bc, tbc) &&
                      !(state_icb == ICB_LINKER && ticb == ICB_CONSONANT)   # GB9c
    if ticb == ICB_CONSONANT || state_icb == ICB_CONSONANT || state_icb == ICB_EXTEND
        state_icb = ticb
    elseif state_icb == ICB_LINKER
        state_icb = ticb == ICB_EXTEND ? ICB_LINKER : ticb
    end
    if state_bc == tbc && tbc == REGIONAL_INDICATOR
        state_bc = OTHER
    elseif state_bc == EXTENDED_PICTOGRAPHIC
        state_bc = tbc == EXTEND ? EXTENDED_PICTOGRAPHIC : tbc == ZWJ ? E_ZWG : tbc
    else
        state_bc = tbc
    end
    unsafe_store!(state, Int32(state_bc + (state_icb << 8)))
    return break_permitted
end

end
