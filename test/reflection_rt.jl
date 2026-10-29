# Reflection the module answers at run time without the C runtime: modules (parentmodule,
# PkgId, moduleloc, show), fieldtype of a field known only at run time, the
# parser's operator tables (show of Symbols and Modules).

module ReflectionRT

using Test
import Random, TOML
using ..Main: wcompile, wasm_run, @wtest, WasmCodegen

module Outer
module Inner
struct T; x::Int; end
end
end

const MODS = Module[Base, Core, Main, Random, TOML, Outer, Outer.Inner, Base.Iterators, Base.Filesystem, Random.DSFMT]
mod_at(i::Int) = MODS[i]
mod_parent(i::Int) = something(findfirst(m -> m === parentmodule(mod_at(i)), MODS), 0)
function mod_query(i::Int)
    m = mod_at(i)
    p = parentmodule(m)
    id = Base.PkgId(m)
    u = id.uuid === nothing ? UInt128(0) : UInt128(id.uuid)
    loc = Base.moduleloc(m)
    return (something(findfirst(x -> x === p, MODS), 0), u, hash(id.name), loc.line,
            hash(String(loc.file)), hash(sprint(show, m)), hash(string(nameof(m))))
end
# `jl_module_getloc` with no line pointer (chosen at run time): only the file
mod_file(i::Int, null::Bool) = (line = Ref{Int32}(0);
    f = GC.@preserve line ccall(:jl_module_getloc, Ref{Symbol}, (Any, Ptr{Int32}), mod_at(i),
                                null ? Ptr{Int32}(C_NULL) : Base.unsafe_convert(Ptr{Int32}, line));
    (hash(String(f)), line[]))

# the operator ccalls in Wasm, of names chosen at run time
const OPNAMES = ["+", "+₁", ".+", "->", "&&", "a", "", "′+", "in", "√", "..."]
function op_queries(i::Int)
    s = OPNAMES[i]
    GC.@preserve s begin
        p = Base.unsafe_convert(Cstring, s)
        (ccall(:jl_is_operator, Cint, (Cstring,), p), ccall(:jl_is_unary_operator, Cint, (Cstring,), p),
         ccall(:jl_is_unary_and_binary_operator, Cint, (Cstring,), p),
         ccall(:jl_is_syntactic_operator, Cint, (Cstring,), p), ccall(:jl_operator_precedence, Cint, (Cstring,), p),
         ccall(:jl_op_suffix_char, Cint, (UInt32,), UInt32(i == 2 ? '₁' : i == 8 ? '′' : 'x')))
    end
end

# fieldtype and setproperty! with a field known only at run time
mutable struct Mixed; a::Int; b::String; c::Union{Nothing,Float64}; end
fieldname_at(k::Int) = (:a, :b, :c, :zz)[k]
ft(k::Int) = (T = fieldtype(Mixed, fieldname_at(k)); (T === Int, T === String, T === Union{Nothing,Float64}))
ft_index(k::Int) = (T = fieldtype(Mixed, k); (T === Int, T === String))
# (as Base's setproperty! of a Ref{Bool} to nothing: the conversion to the field's type fails)
function setprop(k::Int)
    r = Ref(true)
    try
        setproperty!(r, (:x, :zz)[k], nothing)
        return (r[], 0)
    catch e
        return (r[], e isa MethodError ? 1 : e isa FieldError ? 2 : 3)
    end
end

@testset "run-time reflection without the C runtime" begin
    @testset "modules" begin
        for i in 1:length(MODS)
            @wtest mod_parent(i)
            @wtest mod_query(i)
            @wtest mod_file(i, true)
            @wtest mod_file(i, false)
        end
    end
    @testset "fieldtype" begin
        for k in 1:4
            @wtest ft(k)
        end
        for k in 0:4
            @wtest ft_index(k)
        end
        @wtest setprop(1)
        @wtest setprop(2)
    end
    @testset "operator ccalls in Wasm" begin
        for i in 1:length(OPNAMES)
            @wtest op_queries(i)
        end
    end
    @testset "operator tables against the native parser" begin
        O = WasmCodegen.Runtime.Operators
        natives = (s -> ccall(:jl_is_operator, Cint, (Cstring,), s), s -> ccall(:jl_is_unary_operator, Cint, (Cstring,), s),
                   s -> ccall(:jl_is_unary_and_binary_operator, Cint, (Cstring,), s),
                   s -> ccall(:jl_is_syntactic_operator, Cint, (Cstring,), s), s -> ccall(:jl_operator_precedence, Cint, (Cstring,), s))
        ports = (O.is_operator, O.is_unary_operator, O.is_unary_and_binary_operator, O.is_syntactic_operator, O.operator_precedence)
        cands = String[O.OPERATOR_LIST; first.(O.PRECEDENCE_LIST); ["", "a", "₁", "′+", "in", "isa", "x+", "++", "..", "....", "&&&"]]
        for op in O.OPERATOR_LIST, suf in ("₁", "′", "\u0301", "ᵀ", "x")
            push!(cands, op * suf)
        end
        for c in 0x21:0x7e
            push!(cands, string(Char(c)), "." * Char(c))
        end
        bad = 0
        for s in cands, (n, p) in zip(natives, ports)
            bad += GC.@preserve(s, p(Base.unsafe_convert(Cstring, s))) != n(s)
        end
        @test bad == 0
        @test all(c -> ccall(:jl_op_suffix_char, Cint, (UInt32,), c) == O.op_suffix_char(c),
                  UInt32[c for c in 0x0:0x10ffff if !(0xd800 <= c <= 0xdfff)])
    end
end

end
