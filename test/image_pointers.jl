# Pointers of the build process in the image: addresses without an owner, which mean nothing
# in the module. Null pointers are serialized; another is an unsupported construct, unless
# its field is allowlisted (`Config(image_pointer_fields)`).

module ImagePointers
struct PtrHolder
    p::Ptr{UInt8}
    n::Int
end
global g_null_cstring::Cstring = reinterpret(Cstring, C_NULL)
global g_cstring::Cstring = reinterpret(Cstring, Ptr{UInt8}(UInt(0x10)))
global g_holder::PtrHolder = PtrHolder(Ptr{UInt8}(UInt(0x1000)), 3)
global g_null_holder::PtrHolder = PtrHolder(C_NULL, 4)
mutable struct MutablePtrHolder
    p::Ptr{UInt8}
end
const MPH = MutablePtrHolder(Ptr{UInt8}(UInt(0x2000)))
read_mph() = UInt(MPH.p)
null_cstring() = reinterpret(UInt, g_null_cstring) == 0
read_cstring() = reinterpret(UInt, g_cstring)
read_holder() = UInt(g_holder.p) + UInt(g_holder.n)
read_null_holder() = UInt(g_null_holder.p) + UInt(g_null_holder.n)
# a pointer boxed where the field is a union or `Any`
mutable struct UnionPtrHolder
    p::Union{Nothing,Ptr{UInt8}}
end
struct AnyPtrHolder
    p::Any
end
const UPH = UnionPtrHolder(Ptr{UInt8}(UInt(0x3000)))
# (globals, not constants, of immutable holders: inference would fold their reads)
global APH::AnyPtrHolder = AnyPtrHolder(Ptr{UInt8}(UInt(0x4000)))
read_uph() = (p = UPH.p; p === nothing ? UInt(0) : UInt(p))
read_aph() = UInt(APH.p::Ptr{UInt8})
# C strings in fields
struct CstrHolder
    s::Cstring
    w::Cwstring
end
global CSH::CstrHolder = CstrHolder(reinterpret(Cstring, Ptr{UInt8}(UInt(0x5000))), reinterpret(Cwstring, C_NULL))
read_csh() = (reinterpret(UInt, CSH.s), reinterpret(UInt, CSH.w))
# an allowlisted field and a Memory holding the same pointer: the Memory's is rejected
mutable struct MixedRoot
    h::UnionPtrHolder
    m::Memory{Ptr{UInt8}}
end
const MIXED = MixedRoot(UPH, let m = Memory{Ptr{UInt8}}(undef, 1); m[1] = Ptr{UInt8}(UInt(0x3000)); m end)
read_mixed() = (p = MIXED.h.p; (p === nothing ? UInt(0) : UInt(p)) + UInt(MIXED.m[1]))
global NULL_CSH::CstrHolder = CstrHolder(reinterpret(Cstring, C_NULL), reinterpret(Cwstring, C_NULL))
read_null_csh() = (reinterpret(UInt, NULL_CSH.s), reinterpret(UInt, NULL_CSH.w))
end

@testset "image pointers" begin
    P = ImagePointers
    # null pointers (C_NULL), of any pointer type, are serialized
    @wtest P.null_cstring()
    @wtest P.read_null_holder()
    # another pointer is an unsupported construct (it was a compiler crash for Cstring)
    for f in (P.read_cstring, P.read_holder)
        err = try
            WasmCodegen.compile(f, ())
            nothing
        catch e
            e
        end
        @test err isa WasmCodegen.UnsupportedConstructs
        @test err isa WasmCodegen.UnsupportedConstructs &&
              occursin("a pointer of the build process in the image", sprint(showerror, err))
    end
    # unless its field is allowlisted: its address as it is
    c = WasmCodegen.compile(P.read_holder, (); config=WasmCodegen.Config(image_pointer_fields=[(P.PtrHolder, :p)]))
    @test wasm_run(c, "read_holder"; rettype=UInt) == UInt(0x1003)
    # a field of a mutable object too
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(P.read_mph, ())
    c = WasmCodegen.compile(P.read_mph, (); config=WasmCodegen.Config(image_pointer_fields=[(P.MutablePtrHolder, :p)]))
    @test wasm_run(c, "read_mph"; rettype=UInt) == UInt(0x2000)
    # boxed in a union or `Any` field: rejected, or as it is when allowlisted
    for (f, H, addr) in ((P.read_uph, P.UnionPtrHolder, 0x3000), (P.read_aph, P.AnyPtrHolder, 0x4000))
        @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(f, ())
        c = WasmCodegen.compile(f, (); config=WasmCodegen.Config(image_pointer_fields=[(H, :p)]))
        @test wasm_run(c, string(nameof(f)); rettype=UInt) == UInt(addr) == f()
    end
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(P.read_mixed, ();
        config=WasmCodegen.Config(image_pointer_fields=[(P.UnionPtrHolder, :p)]))
    # C strings in fields: null ones serialized, another as it is when allowlisted
    @wtest P.read_null_csh()
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(P.read_csh, ())
    c = WasmCodegen.compile(P.read_csh, (); config=WasmCodegen.Config(image_pointer_fields=[(P.CstrHolder, :s)]))
    @test wasm_run(c, "read_csh"; rettype=Tuple{UInt,UInt}) == (UInt(0x5000), UInt(0)) == P.read_csh()
end

# the runtime's Unicode tables have no unused capacity (the image serializes all of a Memory)
@testset "image: Unicode tables" begin
    U = WasmCodegen.Runtime.UnicodeData
    for name in (:CATEGORY, :ID_CHAR, :ID_START_CHAR, :BOUNDCLASS, :INDIC_CONJUNCT, :IS_UPPER,
                 :CHARWIDTH, :IS_LOWER, :TO_UPPER, :TO_LOWER, :TO_TITLE)
        for v in getfield(U, name)
            @test length(v.ref.mem) == length(v)
        end
    end
end
