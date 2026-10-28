# The bundled trim patch overrides `throw_eachindex_mismatch_indices` with Julia 1.13's
# signature `(indices_str, inds...)` too, so multi-array `eachindex` passes strict verification
# when its caller was inferred into a package image (as with JuliaC.jl#197).
@testset "eachindex mismatch thrower under the trim patches" begin
    WasmCodegen.with_trim_patches() do _, w
        @test hasmethod(Base.throw_eachindex_mismatch_indices, Tuple{String, Base.OneTo{Int}, Base.OneTo{Int}}; world = w)
        msg = sprint(showerror, try
            Base.invoke_in_world(w, Base.throw_eachindex_mismatch_indices, "indices", 1:2, 1:3, 1:4)
        catch e
            e
        end)
        @test msg == "DimensionMismatch: all inputs to eachindex must have the same indices"
        c = WasmCodegen.compile(PrecompiledPrograms.sum4, (Int,); world = w, config = WasmCodegen.Config(verify = :error))
        @test wasm_run(c, "sum4", 10; rettype = Float64) === PrecompiledPrograms.sum4(10)
    end
end
