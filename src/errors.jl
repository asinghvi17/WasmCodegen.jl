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
