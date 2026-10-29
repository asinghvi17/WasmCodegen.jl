# VersionNumbers with prerelease and build parts (trim/wasm-versions.jl): hash and Dicts keyed
# by them, printing (also through an IOContext, and in a module that limits inference to one
# method per call, `@max_methods 1`, as Pkg's modules do).

module VersionTests

using Test
using ..Main: wcompile, wasm_run, @wtest

const VS = [v"1.2.3", v"1.2.3-alpha", v"1.2.3-alpha.1", v"1.2.3+build.7", v"1.2.3-rc.2+b5",
            v"0.0.0", v"1.13.2", v"1.13.2-DEV.1+abc.2", v"2.0.0-0.3.7", v"1.0.0-x.7.z.92"]
const N = length(VS)

# the hash of the parts against Base's recursive definition, computed natively here
ref_hash(t::Tuple, h::UInt) = isempty(t) ? hash((), h) : hash(t[1], ref_hash(Base.tail(t), h))
# Base's hash(::VersionNumber) (version.jl), with the parts by ref_hash
function ref_vhash(v::VersionNumber, h::UInt)
    h = VERSION >= v"1.13-" ? h ⊻ (0x8ff4ffdb75f9fede % UInt) : h + (0x8ff4ffdb75f9fede % UInt)
    h = hash(v.major, h); h = hash(v.minor, h); h = hash(v.patch, h)
    h = ref_hash(v.prerelease, ~h)
    return ref_hash(v.build, ~h)
end
# (the seed of `hash(x)`: zero before Julia 1.13)
const HASH_SEED = isdefined(Base, :HASH_SEED) ? Base.HASH_SEED : zero(UInt)
const VMAX = typemax(VersionNumber)
vn_vhash(i::Int) = (hash(VS[i]), hash(VS[i], UInt(42)))
vn_parts_hash(i::Int) = (hash(VS[i].prerelease, UInt(3)), hash(VS[i].build, UInt(0)))
vn_hash(i::Int) = (hash(VS[i]), hash(VS[i].prerelease), hash(VS[i].build, UInt(7)))
function vn_dict(n::Int)
    d = Dict{VersionNumber,Int}()
    for k in 1:n, (i, v) in enumerate(VS)
        d[v] = get(d, v, 0) + i
    end
    return (length(d), d[v"1.2.3-alpha.1"], get(d, v"9.9.9", -1), haskey(d, v"1.13.2-DEV.1+abc.2"))
end
vn_string(i::Int) = (s = string(VS[i]); (sizeof(s), hash(s), hash(repr(VS[i]))))
vn_print(i::Int) = (io = IOBuffer(); print(io, VS[i], " "); join(io, VS[i].prerelease, '.'); show(io, VS[i]);
                    s = String(take!(io)); (sizeof(s), hash(s)))

# printed through an IOContext from a function not inlined (as the resolver's log does),
# and the largest version (printed as ∞)
@noinline print_ctx(io::IO, v::VersionNumber) = (print(IOContext(io, :compact => true), "v=", v, ";"); nothing)
function vn_print_ctx(i::Int)
    io = IOBuffer()
    print_ctx(io, VS[i])
    print(IOContext(io, :color => false), VS[i], VMAX)
    s = String(take!(io))
    return (sizeof(s), hash(s), hash(sprint(print, VS[i])), hash(sprint(show, VS[i])))
end

# the text Base prints, as literals (`@wtest`'s native references run the patched methods)
const VS_TEXT = ["1.2.3", "1.2.3-alpha", "1.2.3-alpha.1", "1.2.3+build.7", "1.2.3-rc.2+b5",
                 "0.0.0", "1.13.2", "1.13.2-DEV.1+abc.2", "2.0.0-0.3.7", "1.0.0-x.7.z.92"]
const SPECIAL = (v"0-", v"1+", VMAX)
const SPECIAL_TEXT = ("0.0.0-", "1.0.0+", "∞")
vn_text(i::Int) = string(VS[i]) == VS_TEXT[i] && repr(VS[i]) == string("v\"", VS_TEXT[i], "\"")
vn_special_text(k::Int) = string(SPECIAL[k]) == SPECIAL_TEXT[k]

# as in Pkg's modules: one method per call
module MaxMethods1
Base.Experimental.@max_methods 1
pre_str(v::VersionNumber) = (io = IOBuffer(); join(io, v.prerelease, '.'); String(take!(io)))
printed(v::VersionNumber) = (io = IOBuffer(); print(IOContext(io, :limit => true), "version ", v); String(take!(io)))
end
function vn_maxmethods1(i::Int)
    v = VS[i]
    s = MaxMethods1.pre_str(v)
    return (sizeof(s), hash(s), hash(MaxMethods1.printed(v)), hash(v))
end

@testset "VersionNumber hash and printing" begin
    for f in (vn_hash, vn_string, vn_print, vn_print_ctx, vn_maxmethods1)
        @testset "$(nameof(f))" begin
            for i in 1:N
                @wtest f(i)
            end
        end
    end
    @testset "Dict" begin @wtest vn_dict(3) end
    @testset "text" begin
        for i in 1:N
            @test vn_text(i)
            @wtest vn_text(i)
        end
        for k in 1:length(SPECIAL)
            @test vn_special_text(k)
            @wtest vn_special_text(k)
        end
    end
    @testset "hash against Base's recursive definition" begin
        c = wcompile(vn_parts_hash, (Int,))
        for i in 1:N
            @test wasm_run(c, "vn_parts_hash", i; rettype=Tuple{UInt,UInt}) ==
                  (ref_hash(VS[i].prerelease, UInt(3)), ref_hash(VS[i].build, UInt(0)))
        end
        c = wcompile(vn_vhash, (Int,))
        for i in 1:N
            @test wasm_run(c, "vn_vhash", i; rettype=Tuple{UInt,UInt}) ==
                  (ref_vhash(VS[i], HASH_SEED), ref_vhash(VS[i], UInt(42)))
        end
    end
end

end
