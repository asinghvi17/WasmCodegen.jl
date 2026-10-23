# JuliaSyntax, Julia's parser (shipped in Base as `Base.JuliaSyntax`), compiled to WebAssembly.
#
# The page writes the source's UTF-8 bytes into the module, parses, and reads back the
# parser's raw output, as JuliaSyntax's own tree builders do: the tokens and the ranges of
# the green tree, in postorder, then the diagnostics. Only numbers cross the boundary.

const JS = Base.JuliaSyntax

const SRC = UInt8[]
const STREAM = Ref{JS.ParseStream}()

"Make room for `n` bytes of source."
src_resize(n::Int32)::Int32 = (resize!(SRC, n); Int32(length(SRC)))

"Set the byte `i` (1-based) of the source."
src_set(i::Int32, b::Int32)::Int32 = (SRC[i] = b % UInt8; Int32(0))

"Parse the source (`rule` 1: a file, 2: a statement, 3: an atom); the number of output nodes."
function parse_src(rule::Int32)::Int32
    stream = JS.ParseStream(copy(SRC))
    JS.parse!(stream; rule = rule == 1 ? :all : rule == 2 ? :statement : :atom)
    STREAM[] = stream
    return Int32(length(stream.output))
end

node(i::Int32) = STREAM[].output[i]

"The kind of the output node `i`, as JuliaSyntax numbers kinds."
out_kind(i::Int32)::Int32 = Int32(reinterpret(UInt16, JS.kind(node(i))))

"The number of bytes the output node `i` covers."
out_span(i::Int32)::Int32 = Int32(node(i).byte_span)

"For an interior node, the number of nodes below it; for a token, its kind before parsing."
out_nodespan(i::Int32)::Int32 = Int32(node(i).node_span_or_orig_kind)

"""
The classes of the output node `i`, as bits: 1 interior node, 2 trivia, 4 error,
8 keyword, 16 operator, 32 literal, 64 identifier, 128 whitespace or comment."""
function out_class(i::Int32)::Int32
    n = node(i)
    k = JS.kind(n)
    c = 0
    JS.is_non_terminal(n) && (c |= 1)
    JS.is_trivia(n) && (c |= 2)
    JS.is_error(k) && (c |= 4)
    JS.is_keyword(k) && (c |= 8)
    JS.is_operator(k) && (c |= 16)
    JS.is_literal(k) && (c |= 32)
    JS.is_identifier(k) && (c |= 64)
    JS.is_whitespace(k) && (c |= 128)
    return Int32(c)
end

"The number of diagnostics of the last parse."
ndiag()::Int32 = Int32(length(STREAM[].diagnostics))
diag_first(i::Int32)::Int32 = Int32(STREAM[].diagnostics[i].first_byte)
diag_last(i::Int32)::Int32 = Int32(STREAM[].diagnostics[i].last_byte)
"1: error, 2: warning, 3: other."
diag_level(i::Int32)::Int32 = (l = STREAM[].diagnostics[i].level; l === :error ? Int32(1) : l === :warning ? Int32(2) : Int32(3))
diag_msg_len(i::Int32)::Int32 = Int32(ncodeunits(STREAM[].diagnostics[i].message))
diag_msg_byte(i::Int32, j::Int32)::Int32 = Int32(codeunit(STREAM[].diagnostics[i].message, j))

"The name of the kind `k` (as JuliaSyntax prints it), byte by byte."
kind_name(k::Int32) = string(reinterpret(JS.Kind, UInt16(k)))
kind_name_len(k::Int32)::Int32 = Int32(ncodeunits(kind_name(k)))
kind_name_byte(k::Int32, j::Int32)::Int32 = Int32(codeunit(kind_name(k), j))

const ENTRIES = [(src_resize, (Int32,)), (src_set, (Int32, Int32)), (parse_src, (Int32,)),
                 (out_kind, (Int32,)), (out_span, (Int32,)), (out_nodespan, (Int32,)),
                 (out_class, (Int32,)), (ndiag, ()), (diag_first, (Int32,)), (diag_last, (Int32,)),
                 (diag_level, (Int32,)), (diag_msg_len, (Int32,)), (diag_msg_byte, (Int32, Int32)),
                 (kind_name_len, (Int32,)), (kind_name_byte, (Int32, Int32))]
