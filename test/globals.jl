# Global variables of every kind of declared type: read, assigned in Wasm, and compared with
# native Julia from the same state (the module starts from their values when it is compiled,
# so each program is compiled before it runs natively).

struct GPoint; x::Float64; y::Float64; end
global g_int::Int = 1
global g_float::Float64 = 0.5
global g_point::GPoint = GPoint(1.0, 2.0)
global g_vec::Vector{Int} = [1, 2, 3]
global g_str::String = "hello"
global g_real::Real = 3                # an abstract declared type: boxed
global g_union::Union{Nothing,Int} = nothing
global g_tuple::Tuple{Int,Float64} = (1, 2.0)
global g_untyped = 42                  # binding type Any

bump_int(n::Int) = (global g_int += n; g_int)
bump_float(x::Float64) = (global g_float *= x; g_float)
move_point(dx::Float64) = (global g_point = GPoint(g_point.x + dx, g_point.y); g_point.x + g_point.y)
push_vec(n::Int) = (push!(g_vec, n); global g_vec = vcat(g_vec, [n]); sum(g_vec))
grow_str(n::Int) = (global g_str = g_str * string(n); ncodeunits(g_str))
real_global(x::Float64) = (global g_real = x; g_real isa Float64 ? 1 : 0)
union_global(n::Int) = (u = g_union; global g_union = n; u === nothing ? -1 : u)
tuple_global(n::Int) = (global g_tuple = (g_tuple[1] + n, g_tuple[2] * 2); g_tuple[1] + g_tuple[2])
untyped_global(n::Int) = (global g_untyped = n + (g_untyped::Int); g_untyped::Int)

@testset "typed globals" begin
    for (f, args) in ((bump_int, (5,)), (bump_float, (3.0,)), (move_point, (0.5,)), (push_vec, (4,)),
                      (grow_str, (12,)), (real_global, (2.5,)), (union_global, (7,)),
                      (tuple_global, (3,)), (untyped_global, (1,)))
        c = WasmCodegen.compile(f, map(Core.Typeof, args))
        expected = Base.invokelatest(f, args...)
        got = wasm_run(c, string(nameof(f)), args...; rettype=typeof(expected))
        @test isequal(got, expected)
    end
end
