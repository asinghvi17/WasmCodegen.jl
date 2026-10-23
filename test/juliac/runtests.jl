using .JuliaCPrograms: jc_add_one, untrimmable, sum_areas, reductions, nested_reductions, cats,
    app_main, math_main

@testset "JuliaC programs" begin
    @wtest jc_add_one(Cint(41))
    @wtest sum_areas()
    @wtest reductions(10)
    @wtest nested_reductions()
    @wtest cats()
    # printing: the output is what native Julia prints
    for (f, args, expected) in ((app_main, (), "Fast compilation test!\n"),
                                (math_main, (1.0,), string("sin(", 1.0, ") = ", sin(1.0), "\n")),
                                (math_main, (0.5,), string("sin(", 0.5, ") = ", sin(0.5), "\n")))
        c = wcompile(f, map(typeof, args))
        @test wasm_run(c, string(nameof(f)), args...; rettype=Cint) == 0
        @test LAST_OUTPUT[] == expected
        LAST_OUTPUT[] == expected || @info "output" expected got=LAST_OUTPUT[]
    end
    # dynamic dispatch: rejected, as by juliac --trim=safe
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(untrimmable, (Int,); config=WasmCodegen.Config(verify=:off))
end
