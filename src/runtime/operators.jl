# The parser's operator predicates (Julia's flisp front end, src/julia-parser.scm), which
# printing (`show` of a Symbol or an Expr, `Meta.isoperator`, `Base.operator_precedence`)
# asks the C runtime about: `jl_is_operator`, `jl_is_unary_operator`,
# `jl_is_unary_and_binary_operator`, `jl_is_syntactic_operator`, `jl_operator_precedence`,
# `jl_op_suffix_char`. The candidates (`operators_data.jl`) are generated from a native parser
# by `gen_operators.jl`; the tables are those of them the running Julia's parser accepts
# (asked when the package is loaded), so they match the Julia that compiles the program
# (`🢲`, for example, is an operator from Julia 1.12.3 on). A Julia newer than the one the
# candidates come from may have operators they lack: regenerate them (the tests compare the
# tables with the native parser).

module Operators

import ..UnicodeData
import ..ptr_strlen

include("operators_data.jl")

# the candidates the native parser accepts
accepted(pred, list) = Set{String}(s for s in list if pred(s) != 0)
const OPERATORS = accepted(s -> ccall(:jl_is_operator, Cint, (Cstring,), s), OPERATOR_LIST)
const NO_SUFFIX = Set{String}(NO_SUFFIX_LIST)
const UNARY = accepted(s -> ccall(:jl_is_unary_operator, Cint, (Cstring,), s), UNARY_LIST)
const UNARY_AND_BINARY = accepted(s -> ccall(:jl_is_unary_and_binary_operator, Cint, (Cstring,), s),
                                  UNARY_AND_BINARY_LIST)
const SYNTACTIC = accepted(s -> ccall(:jl_is_syntactic_operator, Cint, (Cstring,), s), SYNTACTIC_LIST)
const PRECEDENCE = Dict{String,Int}(op => p for op in first.(PRECEDENCE_LIST)
                                    for p in (Int(ccall(:jl_operator_precedence, Cint, (Cstring,), op)),) if p != 0)
const SUFFIX_CHARS = Set{UInt32}(c for c in OP_SUFFIX_CHARS if ccall(:jl_op_suffix_char, Cint, (UInt32,), c) != 0)

# utf8proc's categories of combining marks (Mn, Mc, Me)
const MARKS = (Int32(Base.Unicode.UTF8PROC_CATEGORY_MN), Int32(Base.Unicode.UTF8PROC_CATEGORY_MC),
               Int32(Base.Unicode.UTF8PROC_CATEGORY_ME))

"`jl_op_suffix_char(c)`: whether the character `c` can follow an operator as part of it."
function op_suffix_char(c::UInt32)
    (c < 0xa1 || c > 0x10ffff) && return Cint(0)
    UnicodeData.category(c) in MARKS && return Cint(1)
    return Cint(c in SUFFIX_CHARS)
end

# `strip-op-suffix`: the name before its first suffix character (unless that is the first)
function strip_suffix(s::String)
    i = firstindex(s)
    while i <= ncodeunits(s)
        c = s[i]
        if isvalid(c) && op_suffix_char(UInt32(c)) != 0
            return i == 1 ? s : s[1:prevind(s, i)]
        end
        i = nextind(s, i)
    end
    return s
end

# `maybe-strip-op-suffix`: without its suffix, for the operators that may have one
function maybe_strip(s::String)
    t = strip_suffix(s)
    return t === s || t in NO_SUFFIX ? s : t
end

name(p::Cstring) = (q = convert(Ptr{UInt8}, p); unsafe_string(q, ptr_strlen(q)))

"`jl_is_operator(name)`"
is_operator(p::Cstring) = Cint(maybe_strip(name(p)) in OPERATORS)
"`jl_is_unary_operator(name)`"
is_unary_operator(p::Cstring) = Cint(name(p) in UNARY)
"`jl_is_unary_and_binary_operator(name)`"
is_unary_and_binary_operator(p::Cstring) = Cint(name(p) in UNARY_AND_BINARY)
"`jl_is_syntactic_operator(name)`"
is_syntactic_operator(p::Cstring) = Cint(name(p) in SYNTACTIC)
"`jl_operator_precedence(name)`: 0 for a name that is not a binary operator."
operator_precedence(p::Cstring) = Cint(get(PRECEDENCE, maybe_strip(name(p)), 0))

end
