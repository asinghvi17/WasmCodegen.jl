using Test
include("paths.jl")

mutable struct Counter
    value::Int32
end
reset_counter!(s::Counter) = (s.value = 0; nothing)
@noinline private_helper(x::Int32)::Int32 = x * Int32(7)
counter_value(s::Counter, x::Int32)::Int32 = private_helper(x) + s.value
high32(s::Counter)::UInt32 = typemax(UInt32)
high64(s::Counter)::UInt64 = typemax(UInt64)
unreachable_root(x::Int32)::Int32 = x * Int32(13)

function counter_spec(n=2; setup=(_ -> Counter(99)), exports=nothing)
    es = isnothing(exports) ?
        [ExportSpec(:value, counter_value, (Int32,); returns=Int32),
         ExportSpec(:high32, high32, (); returns=UInt32),
         ExportSpec(:high64, high64, (); returns=UInt64),
         ExportSpec(:lookup, counter_value, (Int32,); returns=Int32)] : exports
    ProgramSpec(; name="counter", source=@__FILE__, setup, config=nothing, exports=es,
        instances=BakedPool(n), reset=reset_counter!)
end

@testset "staging and native wrappers" begin
    calls = Ref(0)
    p = lower(counter_spec(; setup=_ -> (calls[] += 1; Counter(99))))
    @test calls[] == 2
    @test eltype(getglobal(p.mod, :STATES)) === Counter
    @test getglobal(p.mod, :STATES)[1] !== getglobal(p.mod, :STATES)[2]
    invoke(name, args...) = Base.invokelatest(
        ProgramBuild.latest(p.mod, name in (:create, :destroy) ? name : Symbol("export_", name)), args...)
    @test invoke(:value, UInt64(0), Int32(2)) == (Int32(-1), Int32(0))
    status, h = invoke(:create)
    @test status == 0
    @test invoke(:value, h, Int32(2)) == (Int32(0), Int32(14))
    @test invoke(:destroy, h) == (Int32(0), Int32(0))
    @test first(invoke(:value, h, Int32(2))) == -1
    @test first(invoke(:destroy, h)) == -1
    _, reused = invoke(:create)
    @test reused != h
    @test UInt32(reused & 0xffffffff) == UInt32(h & 0xffffffff)
    # Retire a slot at generation exhaustion instead of allowing stale resurrection.
    invoke(:destroy, reused)
    generations = getglobal(p.mod, :GENERATIONS)
    generations[1] = typemax(UInt32)
    _, last_handle = invoke(:create)
    @test last_handle >> 32 == typemax(UInt32)
    @test first(invoke(:destroy, last_handle)) == 0
    @test generations[1] == 0
    _, remaining = invoke(:create)
    @test remaining & 0xffffffff == 2
    @test invoke(:create) == (Int32(-2), UInt64(0))
    @test first(invoke(:value, last_handle, Int32(2))) == -1

    @test_throws ArgumentError BakedPool(0)
    @test_throws ArgumentError ExportSpec(:create, identity, (); returns=Int32)
    @test_throws ArgumentError ExportSpec(:handle, identity, (); returns=Int32)
    @test_throws ArgumentError ExportSpec(:bad, identity, (Bool,); returns=Int32)
    @test_throws ArgumentError ExportSpec(:bad, identity, (); returns=String)
    @test_throws ArgumentError counter_spec(; exports=fill(
        ExportSpec(:value, counter_value, (Int32,); returns=Int32), 2))
    alternating = Ref(false)
    @test_throws ArgumentError lower(counter_spec(; setup=_ ->
        ((alternating[] = !alternating[]) ? Counter(1) : Ref(Int32(1)))))
    @test_throws ArgumentError lower(counter_spec(; exports=[
        ExportSpec(:wrong, identity, (Int32,); returns=Int32)]))
end

@testset "zero-argument physical ABI JSON" begin
    physical = ProgramBuild.wasm_manifest(counter_spec()).wasm_gc.exports[1]
    encoded = ProgramBuild.JSON.parse(ProgramBuild.JSON.json(physical))
    @test encoded["args"] == []
    @test encoded["wasm_args"] == []
    @test encoded["wasm_returns"] == ["i32", "i64"]
end
