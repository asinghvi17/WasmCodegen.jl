# Errors of the code generator.

"""
    WasmCodegen.Unsupported(parts...)

Thrown when code uses a construct the code generator does not support. The message is the
concatenation of `parts`.
"""
struct Unsupported <: Exception
    parts::Vector{Any}
    context::Vector{Any}
    Unsupported(parts...) = new(Any[parts...], Any[])
end

function Base.showerror(io::IO, e::Unsupported)
    print(io, "WasmCodegen: unsupported: ", e.parts...)
    for c in e.context
        print(io, "\n  in ", c)
    end
end

"Throw an [`Unsupported`](@ref) error with the message `parts`."
unsupported(parts...) = throw(Unsupported(parts...))

"""
    UnsupportedConstructs

The program uses constructs the code generator cannot compile (with `trim = :safe`): every
one, with the function it is in, as juliac's verifier reports dynamic dispatch.
"""
struct UnsupportedConstructs <: Exception
    errors::Vector{Pair{Core.MethodInstance,Unsupported}}
end

function Base.showerror(io::IO, e::UnsupportedConstructs)
    # one line per distinct construct, with how often it occurs
    counts = Dict{String,Int}()
    order = String[]
    for (mi, err) in e.errors
        msg = string("WasmCodegen: unsupported: ", err.parts..., "\n    in ", mi)
        haskey(counts, msg) || push!(order, msg)
        counts[msg] = get(counts, msg, 0) + 1
    end
    print(io, length(e.errors), " unsupported constructs (", length(order), " distinct):")
    for msg in order
        print(io, "\n", msg, counts[msg] > 1 ? "  (×$(counts[msg]))" : "")
    end
end
