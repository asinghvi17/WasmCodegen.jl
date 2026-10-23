include("harness.jl")

# one session of juliac's trim patches for all the tests (as juliac builds in one process)
WasmCodegen.with_trim_patches() do _, _
    include("basics.jl")
    include("data.jl")
end
