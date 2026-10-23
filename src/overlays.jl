# Overlays: methods of Base replaced for Wasm, where Base's implementation uses pointers
# or the C runtime. They are written against `Intrinsics`, functions the code generator
# compiles to Wasm instructions (and that have a native implementation, so that overlaid
# code can also run natively).

"""
    WasmCodegen.Intrinsics

Functions the code generator compiles to Wasm instructions, for overlays.
"""
module Intrinsics

"Copy `n` elements from `src` to `dest` (which may overlap), as `memmove`."
@noinline function memcopy!(dest::MemoryRef{T}, src::MemoryRef{T}, n::Int) where {T}
    Base.unsafe_copyto!(dest, src, n)
    return nothing
end

end

using Base.Experimental: @overlay

@overlay WASM_MT function Base.unsafe_copyto!(dest::MemoryRef{T}, src::MemoryRef{T}, n) where {T}
    n == 0 && return dest
    @boundscheck memoryref(dest, n), memoryref(src, n)
    Intrinsics.memcopy!(dest, src, Int(n))
    return dest
end

# no fused multiply-add on Wasm: Base's exact emulation
@overlay WASM_MT Base.fma(x::Float64, y::Float64, z::Float64) = Base.fma_emulated(x, y, z)
@overlay WASM_MT Base.fma(x::Float32, y::Float32, z::Float32) = Base.fma_emulated(x, y, z)

## the code generator's side

const INTRINSIC_HANDLERS = IdDict{Method,Any}()

function register_intrinsics!()
    empty!(INTRINSIC_HANDLERS)
    for m in methods(Intrinsics.memcopy!)
        INTRINSIC_HANDLERS[m] = emit_memcopy!
    end
end

"""
    emit_intrinsic_call!(fc, mi, ex, typ) -> Union{Nothing,CGVal}

The code of an `:invoke` of a function of `Intrinsics`, or `nothing` for other calls.
"""
function emit_intrinsic_call!(fc::FnCtx, mi::Core.MethodInstance, ex::Expr, @nospecialize(typ))
    isempty(INTRINSIC_HANDLERS) && register_intrinsics!()
    h = get(INTRINSIC_HANDLERS, mi.def, nothing)
    h === nothing && return nothing
    args = CGVal[operand(fc, a) for a in ex.args[3:end]]
    return h(fc, args)
end

function emit_memcopy!(fc::FnCtx, args::Vector{CGVal})
    dest, src, n = args
    ml = memory_layout(fc.cgm.types, ref_eltype(dest.typ))
    n = convert_repr(fc, n, Int)
    push_element_address!(fc, dest, ml)
    push_element_address!(fc, src, ml)
    push_val!(fc, n)
    emit!(fc.b, :i32_wrap_i64)
    if ml.stride != 1
        emit!(fc.b, :i32_const, ml.stride)
        emit!(fc.b, :i32_mul)
    end
    emit!(fc.b, :array_copy, ml.array, ml.array)
    return ghost(Nothing, nothing)
end
