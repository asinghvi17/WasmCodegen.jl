# Unsetting elements of a memory. `deleteat!`, `popfirst!`, `resize!`, `empty!` and copying an
# undefined element over an assigned one unset slots (`_unsetindex!`): for an element stored
# inline that holds references (a `SubString`, a `Tuple{String,Int}`) Base stores null
# pointers over every pointer-size word of it, and the element is undefined. In Wasm such an
# element is a box or reference leaves, which pointer stores cannot reach: the unset is the
# runtime's `unset_element!` (natively, the same stores). Other elements are as in Base.
# Applied with juliac's trim patches (see `patches.jl`).

@eval Base function _unsetindex!(A::MemoryRef{T}) where T
    @_terminates_locally_meta
    @_propagate_inbounds_meta
    @inline
    @boundscheck memoryref(A, 1)
    mem = A.mem
    MemT = typeof(mem)
    arrayelem = datatype_arrayelem(MemT)
    isbits = 0; isboxed = 1; isunion = 2
    arrayelem == isbits && datatype_pointerfree(T::DataType) && return A
    if arrayelem == isboxed
        t = @_gc_preserve_begin mem
        p = Ptr{Ptr{Cvoid}}(@inbounds pointer(A))
        Intrinsics.atomic_pointerset(p, C_NULL, :monotonic)
        @_gc_preserve_end t
    elseif arrayelem != isunion
        $(WasmCodegen.Runtime.unset_element!)(A)
    end
    return A
end
