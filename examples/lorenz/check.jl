using WasmCodegen
include("model.jl")
@show lorenz_solve(10.0, 28.0, 8/3, 1.0) lorenz_point(Int32(4001), Int32(1)) lorenz_steps()
WasmCodegen.with_trim_patches() do _, _
    for (f, at) in ENTRIES
        try
            WasmCodegen.trim_check([WasmCodegen.entry_instance(f, at)])
            println(f, ": juliac --trim=safe ok")
        catch e
            println(f, ": REJECTED")
            println(first(e.report, 2000))
        end
    end
end
