using .JuliaCPrograms: jc_add_one, untrimmable, sum_areas, reductions, nested_reductions, cats

@testset "JuliaC programs" begin
    @wtest jc_add_one(Cint(41))
    @wtest sum_areas()
    @wtest reductions(10)
    @wtest nested_reductions()
    @wtest cats()
    # dynamic dispatch: rejected, as by juliac --trim=safe
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(untrimmable, (Int,); config=WasmCodegen.Config(verify=:off))
end
