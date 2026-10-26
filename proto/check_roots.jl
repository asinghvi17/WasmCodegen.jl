# Establish current compiler policy independently of the frontend declaration.
include("runtests.jl")
using WasmCodegen, JSON
p = lower(counter_spec())
entries = [Entry(ProgramBuild.latest(p.mod,:create),();name="create"),
           Entry(ProgramBuild.latest(p.mod,:destroy),(UInt64,);name="destroy")]
append!(entries,[Entry(ProgramBuild.latest(p.mod,Symbol("export_",e.name)),
    (UInt64,e.argtypes...);name=string(e.name)) for e in p.spec.exports])
unreachable_root(x::Int32)::Int32 = x*Int32(13)
root = Entry(unreachable_root,(Int32,);name="root")
compiled(f,c) = any(mi -> mi.def isa Method && mi.def.name == nameof(f) &&
    mi.def.module === @__MODULE__, keys(c.cgm.funcs))
c = WasmCodegen.with_trim_patches() do _,_
    WasmCodegen.compile(entries;config=Config(verify=:error,trim=:safe,on_unsupported=:error))
end
@test compiled(private_helper,c)
@test !compiled(unreachable_root,c)
@test_throws MethodError WasmCodegen.compile(entries;roots=[root])
r = WasmCodegen.with_trim_patches() do _,_
    WasmCodegen.compile([entries;root];config=Config(verify=:error,trim=:safe,on_unsupported=:error))
end
@test compiled(unreachable_root,r)
@assert isempty(c.world.trim_report[]) && isempty(c.cgm.diagnostics)
write(joinpath(@__DIR__,"build/roots.wasm"),c.bytes)
write(joinpath(@__DIR__,"build/roots-entry.wasm"),r.bytes)
write(joinpath(@__DIR__,"results/roots.json"),JSON.json((; private_callee_emitted=true,
    unused_root_emitted=false, roots_keyword=false, entry_exports_root=true)))
build(counter_spec(),WasmGC();output_dir=joinpath(@__DIR__,"build"))
