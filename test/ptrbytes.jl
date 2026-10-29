# Bytes of mutable objects through pointers (jl_ptr_load_byte/jl_ptr_store_byte) when a field
# is a large isbits value (more than MAX_INLINE_LEAVES leaves): a reference to a tuple's array
# or to a boxed immutable value (the byte helpers were invalid Wasm before)
mutable struct BigBuf            # NTuple{100,UInt8}: a tuple's array of bytes
    buf::NTuple{100,UInt8}
    pad::UInt32
    x::Int
end
mutable struct BigWords          # NTuple{80,UInt32}: a tuple's array of words
    x::UInt64
    w::NTuple{80,UInt32}
end
struct Wide                      # 70 leaves, not one element type: a boxed immutable
    a::NTuple{40,UInt16}
    b::NTuple{30,UInt32}
end
mutable struct BigWide
    x::UInt32
    w::Wide
    y::UInt32
end

# weighted sum of `n` bytes from `p` (a pointer with no static origin)
@noinline function wsum(p::Ptr{UInt8}, offs)
    s = 0
    for o in offs
        s = 31 * s + Int(unsafe_load(p + o)) + o
    end
    return s
end
@noinline poke(p::Ptr{UInt8}, o::Int, v::UInt8) = (unsafe_store!(p + o, v); nothing)

function bigbuf(n::Int)
    m = BigBuf(ntuple(i -> UInt8((i * 7 + n) % 256), Val(100)), 0xa1b2c3d4, n * 1000003)
    GC.@preserve m wsum(Ptr{UInt8}(pointer_from_objref(m)), [0:99; 100:103; 104:111])
end
function bigwords(n::Int)
    m = BigWords(0x0102030405060708 + n, ntuple(i -> UInt32(i * 0x01010101 + n), Val(80)))
    GC.@preserve m wsum(Ptr{UInt8}(pointer_from_objref(m)), 0:sizeof(BigWords)-1)
end
function bigwide(n::Int)
    w = Wide(ntuple(i -> UInt16(i * 257 + n), Val(40)), ntuple(i -> UInt32(i * 65537 + n), Val(30)))
    m = BigWide(0xdeadbeef, w, UInt32(n))
    GC.@preserve m wsum(Ptr{UInt8}(pointer_from_objref(m)), 0:sizeof(BigWide)-1)
end
# a store into the small fields of such an object works; into a large field, it traps
function bigbuf_store(o::Int)
    m = BigBuf(ntuple(i -> UInt8(i), Val(100)), 0, 0)
    GC.@preserve m poke(Ptr{UInt8}(pointer_from_objref(m)), o, 0x5a)
    return m.x + Int(m.pad) + Int(m.buf[1])
end

# a Ref of a large isbits struct with pointer fields: bytes
# of its numeric leaves read, of its pointers too (null), through a pointer with no static
# origin
struct ManyFields
    a::NTuple{20,Int8}
    p::Ptr{UInt8}
    b::NTuple{50,Int16}
    q::Ptr{Cvoid}
    c::UInt64
end
function ref_manyfields(n::Int)
    r = Ref(ManyFields(ntuple(i -> Int8(i + n), Val(20)), C_NULL, ntuple(i -> Int16(i * 300 + n), Val(50)), C_NULL, 0x1122334455667788))
    GC.@preserve r wsum(Ptr{UInt8}(pointer_from_objref(r)), [0:19; 24:31; 32:131; 136:143; 144:151])
end
# a store into a byte of a large field (shared box or tuple array) traps, not a silent no-op
function bigwide_store(o::Int)
    m = BigWide(0x01020304, Wide(ntuple(i -> UInt16(i), Val(40)), ntuple(i -> UInt32(i), Val(30))), 0x05060708)
    GC.@preserve m poke(Ptr{UInt8}(pointer_from_objref(m)), o, 0x5a)
    return Int(m.x) + Int(m.y)
end
# a field of a union of isbits types is stored inline, not as isbits leaves: its bytes (the
# value's and the selector's) are not addressable, a pointer access traps
mutable struct BigUnion
    buf::NTuple{65,UInt8}
    u::Union{UInt8,UInt16}
    x::Int
end
function bigunion_load(o::Int)
    m = BigUnion(ntuple(i -> UInt8(i), Val(65)), UInt16(0x1234), 7)
    GC.@preserve m unsafe_load(Ptr{UInt8}(pointer_from_objref(m)) + o)
end
function bigunion_store(o::Int)
    m = BigUnion(ntuple(i -> UInt8(i), Val(65)), UInt16(0x1234), 7)
    GC.@preserve m unsafe_store!(Ptr{UInt8}(pointer_from_objref(m)) + o, 0x5a)
    return Int(m.u) + m.x
end
# SHA hashes (a smoke test of code reading bytes through pointers)
import SHA
sha_hashes(k::Int) = (s = repeat("abc", k); (hash(SHA.sha512(s)), hash(SHA.sha256(s)), hash(SHA.sha1(s))))

@testset "pointer bytes of large isbits fields" begin
    @wtest ref_manyfields(3)
    @wtest bigwide_store(0)      # x: a small field
    r = wasm_run(wcompile(bigwide_store, (Int,)), "bigwide_store", 8; rettype=Int)   # inside w
    @test r isa Tuple && r[1] === :trap
    @wtest sha_hashes(1)
    @wtest sha_hashes(100)
    @test sizeof(BigBuf) == 112 && sizeof(BigWords) == 328 && sizeof(BigWide) == 208
    @wtest bigbuf(3)
    @wtest bigwords(5)
    @wtest bigwide(7)
    @wtest bigbuf_store(104)     # x
    @wtest bigbuf_store(100)     # pad
    c = wcompile(bigbuf_store, (Int,))
    r = wasm_run(c, "bigbuf_store", 0; rettype=Int)
    @test r isa Tuple && r[1] === :trap
    U, X = Int(fieldoffset(BigUnion, 2)), Int(fieldoffset(BigUnion, 3))
    @wtest bigunion_load(3)
    @wtest bigunion_load(X)
    @wtest bigunion_store(X)
    for o in U:X-1
        r = wasm_run(wcompile(bigunion_load, (Int,)), "bigunion_load", o; rettype=UInt8)
        @test r isa Tuple && r[1] === :trap
        r = wasm_run(wcompile(bigunion_store, (Int,)), "bigunion_store", o; rettype=Int)
        @test r isa Tuple && r[1] === :trap
    end
end
