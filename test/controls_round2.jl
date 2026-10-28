using Test, WasmCodegen
function controls_field_contract(x::Float64)::Float64
    v=x>0 ? (a=1.,b=2.,c=3.,d=4.) : (a=1.,b=2.,c=3.,d=4.,e=5.)
    try getfield(v,5) catch e; e isa BoundsError ? -1. : -2.; end
end
controls_epoch(x::Float64)::Float64=time()+x
@test controls_field_contract(1.) == -1.
@test controls_field_contract(-1.) == 5.
compiler_dir=dirname(Base.locate_package(Base.PkgId(WasmCodegen)))
WasmCodegen.TRIM_PATCHES .= joinpath.(Ref(joinpath(compiler_dir,"trim")),basename.(WasmCodegen.TRIM_PATCHES))
c=compile([Entry(controls_field_contract,(Float64,);name="field"),Entry(controls_epoch,(Float64,);name="clock")];
    config=Config(trim=:safe,verify=:error,on_unsupported=:error,optimize=nothing))
out=joinpath(@__DIR__,"..","out");mkpath(out)
mktempdir(out) do dir
    path=joinpath(dir,"contract.wasm");write(path,c.bytes)
    script=joinpath(dir,"check.mjs")
    write(script,"""
    import fs from 'node:fs';
    const {instance}=await WebAssembly.instantiate(fs.readFileSync(process.argv[2]),{julia:{clock_now:()=>1234.25,hrtime:()=>0n}});
    const e=instance.exports;
    if(e.field(1)!==-1 || e.field(-1)!==5 || e.field(1)!==-1 || e.clock(8)!==1242.25)throw Error('controls compiler contract');
    """)
    @test success(`node $script $path`)
end
