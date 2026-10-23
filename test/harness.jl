# Differential testing: compile, run in Node.js, compare with native Julia.

using Test, WasmCodegen, WasmBuilder, Base64, SHA
import JSON3
import NodeJS_24_jll

# Node.js from NodeJS_24_jll (WasmGC, exnref exceptions, js-string builtins), or the executable
# named by WASMCODEGEN_NODE
node_cmd() = haskey(ENV, "WASMCODEGEN_NODE") ? `$(ENV["WASMCODEGEN_NODE"])` : NodeJS_24_jll.node()

const RUNNER = Ref{Any}(nothing)
const REQ_ID = Ref(0)

function runner()
    r = RUNNER[]
    if r === nothing || !process_running(r)
        r = open(`$(node_cmd()) $(joinpath(@__DIR__, "runner.mjs"))`, "r+")
        readline(r)  # ready
        RUNNER[] = r
    end
    return r
end

wtype_name(t) = t === WasmBuilder.I32 ? "i32" : t === WasmBuilder.I64 ? "i64" :
                t === WasmBuilder.F32 ? "f32" : t === WasmBuilder.F64 ? "f64" : "ref"

# the primitive leaves of a value, as (wasm type name, hex bits)
function arg_leaves(@nospecialize(x))
    T = typeof(x)
    if isprimitivetype(T)
        if T === Float64
            return [("f64", string(reinterpret(UInt64, x), base=16))]
        elseif T === Float32
            return [("f32", string(reinterpret(UInt32, x), base=16))]
        elseif sizeof(T) == 8
            return [("i64", string(Core.bitcast(UInt64, x), base=16))]
        elseif sizeof(T) == 16
            u = Core.bitcast(UInt128, x)
            return [("i64", string(UInt64(u & typemax(UInt64)), base=16)), ("i64", string(UInt64(u >> 64), base=16))]
        else
            u = sizeof(T) == 4 ? Core.bitcast(UInt32, x) : sizeof(T) == 2 ? UInt32(Core.bitcast(UInt16, x)) : UInt32(Core.bitcast(UInt8, x))
            return [("i32", string(u, base=16))]
        end
    end
    sizeof(T) == 0 && return Tuple{String,String}[]
    out = Tuple{String,String}[]
    for i in 1:fieldcount(T)
        append!(out, arg_leaves(getfield(x, i)))
    end
    return out
end

# rebuild a value of type T from hex bits of its leaves
function from_leaves(@nospecialize(T), bits::Vector{String}, pos::Ref{Int})
    if isprimitivetype(T)
        b = parse(UInt128, bits[pos[]]; base=16); pos[] += 1
        if sizeof(T) == 16
            hi = parse(UInt128, bits[pos[]]; base=16); pos[] += 1
            return Core.bitcast(T, b | (hi << 64))
        end
        U = sizeof(T) == 8 ? UInt64 : sizeof(T) == 4 ? UInt32 : sizeof(T) == 2 ? UInt16 : UInt8
        return Core.bitcast(T, U(b & typemax(U)))
    end
    if Base.issingletontype(T)
        return T.instance
    end
    fields = Any[from_leaves(fieldtype(T, i), bits, pos) for i in 1:fieldcount(T)]
    return T <: Tuple ? T(fields) : ccall(:jl_new_structv, Any, (Any, Ptr{Any}, UInt32), T, fields, length(fields))
end

"""
    wasm_run(c::Compilation, name, args...; rettype) -> value, or (:trap, msg)
"""
function wasm_run(c, name::String, args...; rettype)
    r = runner()
    id = (REQ_ID[] += 1)
    wasmid = bytes2hex(sha1(c.bytes))
    leaves = reduce(vcat, [arg_leaves(a) for a in args]; init=Tuple{String,String}[])
    rl = WasmCodegen.layout(c.cgm.types, rettype)
    results = rl.kind === WasmCodegen.Inline ? [wtype_name(l.type) for l in rl.leaves] : String[]
    req = Dict("id" => id, "wasmId" => wasmid, "wasm" => base64encode(c.bytes), "fn" => name,
               "args" => [Dict("t" => t, "bits" => b) for (t, b) in leaves], "results" => results)
    println(r, JSON3.write(req))
    resp = JSON3.read(readline(r))
    haskey(resp, :error) && error("runner: ", resp[:error])
    haskey(resp, :trap) && return (:trap, String(resp[:trap]))
    rl.kind === WasmCodegen.Ghost && return rettype.instance
    return from_leaves(rettype, String[x for x in resp[:results]], Ref(1))
end

const COMPILED = IdDict{Any,Any}()

"""
    wcompile(f, argtypes) -> Compilation (cached)
"""
function wcompile(f, argtypes::Tuple; kw...)
    key = (f, argtypes)
    get!(COMPILED, key) do
        WasmCodegen.compile(f, argtypes; kw...)
    end
end

"""
    @wtest f(args...)

Test that `f(args...)` compiled to Wasm returns what native Julia returns (`isequal`,
of the same type); a native exception must be a trap.
"""
macro wtest(ex)
    Meta.isexpr(ex, :call) || error("@wtest expects a call")
    f = esc(ex.args[1])
    args = map(esc, ex.args[2:end])
    quote
        local f = $f
        local args = ($(args...),)
        local expected = try
            Base.invokelatest(f, args...)
        catch err
            err
        end
        local c = wcompile(f, map(Core.Typeof, args))
        local rt = expected isa Exception ? Union{} : typeof(expected)
        local got = wasm_run(c, string(nameof(f)), args...; rettype=Base.return_types(f, map(Core.Typeof, args))[1])
        if expected isa Exception
            @test got isa Tuple && got[1] === :trap
        else
            @test isequal(got, expected) && typeof(got) === typeof(expected)
            if !(isequal(got, expected) && typeof(got) === typeof(expected))
                @info "mismatch" expected got
            end
        end
    end
end
