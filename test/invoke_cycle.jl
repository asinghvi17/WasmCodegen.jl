# `trim_check` with invokes of method instances native inference leaves without code: the
# specializations of a recursion cycle (as an equality of nested values, `eq` -> `vec_eq`
# -> `elems_eq` -> `eq`, each specialized on its arguments) are inferred as part of
# the cycle, and the invokes of some are of a bare MethodInstance, which juliac's verifier
# rejects ("unresolved invoke"). `trim_check` infers those as entries of their own; the
# verifier checks their code (a dynamic call there is still an error).

@noinline function cyc_eq(@nospecialize(a), @nospecialize(b))
    a isa Int && return b isa Int && a == b
    a isa String && return b isa String && a == b
    a isa Vector || return false
    return cyc_vec_eq(a, b)
end
function cyc_vec_eq(@nospecialize(a), @nospecialize(b))
    a isa Vector{Any} && return cyc_vec_eq_b(a, b)
    a isa Vector{Int} && return cyc_vec_eq_b(a, b)
    a isa Vector{String} && return cyc_vec_eq_b(a, b)
    return cyc_vec_eq_b(a::Vector{Vector{Any}}, b)
end
function cyc_vec_eq_b(a::Vector, @nospecialize(b))
    b isa Vector{Any} && return cyc_elems_eq(a, b)
    b isa Vector{Int} && return cyc_elems_eq(a, b)
    b isa Vector{String} && return cyc_elems_eq(a, b)
    b isa Vector{Vector{Any}} && return cyc_elems_eq(a, b)
    return false
end
function cyc_elems_eq(a::Vector, b::Vector)
    length(a) == length(b) || return false
    for i in eachindex(a, b)
        cyc_eq(a[i], b[i]) || return false
    end
    return true
end
@noinline cyc_id(x) = x
function cyc_count(n::Int)
    vals = cyc_id(Any[1, "s", Any[1, "s"], Int[1, 2], ["a"], Vector{Any}[Any[n]], Any[Any[1, n]], Int[n, 2]])
    c = 0
    for x in vals, y in vals
        c = 2c + cyc_eq(x, y)
        c %= 1_000_003
    end
    return c
end

# invokes of ever deeper types: their targets do not end, so they stay
# unresolved invokes (after a few rounds), and trim_check returns
@noinline function cyc_growing(n::Int, x::T) where T
    n <= 0 && return 0
    invoke(cyc_growing, Tuple{Int, Tuple{T}}, n - 1, (x,))
end
cyc_growing_entry(n::Int) = cyc_growing(n, 1)

# the same cycle with a dynamic call in one of its frames
function dyn_elems_eq(a::Vector, b::Vector)
    length(a) == length(b) || return false
    for i in eachindex(a, b)
        Base.inferencebarrier(dyn_eq)(a[i], b[i])::Bool || return false
    end
    return true
end
function dyn_vec_eq(@nospecialize(a), @nospecialize(b))
    a isa Vector{Any} && b isa Vector{Any} && return dyn_elems_eq(a, b)
    a isa Vector{Int} && b isa Vector{Int} && return dyn_elems_eq(a, b)
    return false
end
@noinline dyn_eq(@nospecialize(a), @nospecialize(b)) = a isa Vector ? dyn_vec_eq(a, b) : a === b
dyn_count(n::Int) = dyn_eq(cyc_id(Any[Any[n], Int[2]]), cyc_id(Any[Any[n], Int[2]]))

@testset "trim_check: invokes of instances inferred in a recursion cycle" begin
    mi = WasmCodegen.entry_instance(cyc_count, (Int,))
    args = VERSION >= v"1.13-" ? (WasmCodegen.CC.TRIM_UNSAFE, false) : (WasmCodegen.CC.TRIM_UNSAFE,)
    raw = WasmCodegen.CC.typeinf_ext_toplevel(Any[mi], UInt[Base.get_world_counter()], args...)
    # (the case: native inference leaves invokes of instances without code)
    @test !isempty(WasmCodegen.uncompiled_invoke_targets(raw))
    report = WasmCodegen.trim_check([mi])
    @test !occursin("unresolved invoke", report)
    @wtest cyc_count(3)
    @wtest cyc_count(1)
    # a dynamic call in the cycle's code is still found
    err = try
        WasmCodegen.trim_check([WasmCodegen.entry_instance(dyn_count, (Int,))])
        nothing
    catch e
        e
    end
    @test err isa WasmCodegen.TrimFailure && occursin("unresolved call", err.report) &&
          occursin("dyn_elems_eq", err.report)
    err = try
        WasmCodegen.trim_check([WasmCodegen.entry_instance(cyc_growing_entry, (Int,))])
        nothing
    catch e
        e
    end
    @test err isa WasmCodegen.TrimFailure && occursin("unresolved invoke", err.report)
end
