# The native parser's output for a corpus (reference.json), which check.mjs compares with
# the module's: julia +1.13 --project=. reference.jl
include("parser.jl")
import JSON

snippets = [
    "f(x) = x^2 + 1",
    "for i in 1:3\n  println(i)\nend",
    "a = [1 2; 3 4]'\nb = a .* 2.5f0",
    "x -> (y; z) |> g",
    "struct Foo{T} <: Bar\n    x::T\nend",
    "@time begin\n    sum(abs2, rand(10))\nend",
    "if a\n  b\nelseif c\n  d\nelse\n  e\nend",
    "\"interp \$(x) and \$y\" * raw\"\\n\"",
    "1e400 + 0x1p3 + 1_000.5e-3 + 0b101",
    "function (f::F)(args...; kw...) where {F}\n  f.g(args...; kw...)\nend",
    "α = √2; ∂x = ∇ ⋅ v; 🐱 = 1",
    "try\n  error(\"x\")\ncatch e\n  rethrow()\nfinally\n  done()\nend",
    # syntax errors: the parser recovers
    "f(x",
    "a = = b",
    "begin\n  x +\nend",
    "function f(\n",
    "[1, 2,, 3]",
    "1.0.0",
]
files = String[]
for path in (joinpath(Sys.BINDIR, "..", "share", "julia", "base", "abstractarray.jl"),
             joinpath(Sys.BINDIR, "..", "share", "julia", "base", "JuliaSyntax", "src", "julia", "parser.jl"),
             joinpath(Sys.BINDIR, "..", "share", "julia", "base", "strings", "util.jl"))
    push!(files, read(path, String))
end
cases = []
for (i, src) in enumerate(vcat(snippets, files))
    bytes = Vector{UInt8}(codeunits(src))
    src_resize(Int32(length(bytes)))
    for (j, b) in enumerate(bytes)
        src_set(Int32(j), Int32(b))
    end
    n = parse_src(Int32(1))
    out = [[out_kind(Int32(k)), out_span(Int32(k)), out_nodespan(Int32(k)), out_class(Int32(k))] for k in 1:n]
    diags = [[diag_first(Int32(k)), diag_last(Int32(k)), diag_level(Int32(k)),
              String([UInt8(diag_msg_byte(Int32(k), Int32(j))) for j in 1:diag_msg_len(Int32(k))])] for k in 1:ndiag()]
    names = Dict(string(k) => kind_name(Int32(k)) for k in unique(o[1] for o in out))
    push!(cases, Dict("name" => i <= length(snippets) ? repr(first(src, 30)) : "file $(i - length(snippets)) ($(length(bytes)) bytes)",
                      "src" => src, "out" => out, "diags" => diags, "names" => names))
end
write(joinpath(@__DIR__, "reference.json"), JSON.json(cases))
println(length(cases), " cases, ", sum(c -> length(c["out"]), cases), " output nodes, ",
        sum(c -> length(c["diags"]), cases), " diagnostics")
