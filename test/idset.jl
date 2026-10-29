# IdSet (the C runtime's `jl_idset_*`, `runtime/jlapi.jl`): sets by identity built at run time
# (the index growing from 8- to 16- to 32-bit entries, deletions leaving holes that are
# compacted) and at compile time (found at run time, by the image's native objectids), and
# Base.TOML's parser, which uses them.

# an IdSet of mutable keys built at compile time, with deleted slots and a 16-bit index:
# found through the image's objects, not through fresh equal ones, iterated in native order,
# and changed (on a copy) at run time
const IDSET_REFS = [Ref(i) for i in 1:300]
const IDSET_IMAGE_MUT = let s = Base.IdSet{Any}(IDSET_REFS)
    delete!(s, IDSET_REFS[5]); delete!(s, IDSET_REFS[100]); delete!(s, IDSET_REFS[300])
    s
end
refs_order(s) = (acc = UInt(0); for x in s; acc = acc * 0x1f + UInt((x::Base.RefValue{Int})[]); end; acc)
function idset_image_mutable(k::Int)
    s = IDSET_IMAGE_MUT
    c = copy(s)
    delete!(c, IDSET_REFS[k]); push!(c, IDSET_REFS[5]); push!(c, Ref(1000)); push!(c, IDSET_REFS[300])
    return (length(s), IDSET_REFS[k] in s, IDSET_REFS[5] in s, Ref(k) in s, sizeof(eltype(s.idxs)),
            refs_order(s), length(c), refs_order(c), IDSET_REFS[k] in c, IDSET_REFS[5] in c)
end

# the structure of the index as natively (keys whose objectids are the same in Wasm): its
# entry width, capacity and contents, the keys' memory and `max`, after every step
function idxs_sig(s::Base.IdSet, acc::UInt)
    acc = acc * 0x1f + UInt(sizeof(eltype(s.idxs))); acc = acc * 0x1f + UInt(length(s.idxs))
    for v in s.idxs; acc = acc * 0x1f + UInt(v); end
    acc = acc * 0x1f + UInt(length(s.list)); acc = acc * 0x1f + UInt(s.max)
    return acc
end
# growth through the 8- to 16-bit width change (at 254 keys), with deletions (tombstones)
function idset_structure(n::Int, del::Int)
    s = Base.IdSet{Int}()
    acc = UInt(0)
    for i in 1:n
        push!(s, i * 1009)
        del > 0 && i % del == 0 && delete!(s, (i - 3) * 1009)
        acc = idxs_sig(s, acc)
    end
    return (acc, length(s), sizeof(eltype(s.idxs)), length(s.idxs))
end
# keys that collide in a table of 32 (and of 64): probing to its limit, wrapping around, growth
const IDSET_COLLIDE = let ks = Int[], i = 0
    while length(ks) < 40
        i += 1
        objectid(i) & 63 == 61 && push!(ks, i)
    end
    ks
end
function idset_collide(n::Int)
    s = Base.IdSet{Int}()
    acc = UInt(0)
    for k in IDSET_COLLIDE[1:n]
        push!(s, k); acc = idxs_sig(s, acc)
    end
    for k in IDSET_COLLIDE[1:3:n]
        delete!(s, k); acc = idxs_sig(s, acc)
    end
    return (acc, length(s), all(k -> k in s, IDSET_COLLIDE[2:3:n]))
end
# compaction: keys deleted from a full key memory, then `jl_idset_put_key` (the negative
# `newidx` of a moved key list), with and without growth of the key memory
function idset_compact(n::Int, ndel::Int)
    s = Base.IdSet{Int}()
    for i in 1:n; push!(s, i); end
    while s.max < length(s.list); push!(s, 1000 + s.max); end
    for i in 1:ndel; delete!(s, i * 2); end
    r = Ref{Int}(0)
    list = ccall(:jl_idset_put_key, Any, (Any, Any, Ptr{Int}), s.list, 99999, r)::Memory{Any}
    idxs = ccall(:jl_idset_put_idx, Any, (Any, Any, Int), list, s.idxs, r[])
    acc = UInt(0)
    for v in (idxs::Union{Memory{UInt8},Memory{UInt16},Memory{UInt32}}); acc = acc * 0x1f + UInt(v); end
    found = ccall(:jl_idset_peek_bp, Int, (Any, Any, Any), list, idxs, 99999)
    return (r[], length(list), length(s.list), acc, found)
end

# Base.TOML's parser, which keeps the tables it has defined in IdSets.

function idset_mixed(n::Int)
    s = Base.IdSet{Any}()
    boxes = [Ref(i) for i in 1:n]
    for b in boxes; push!(s, b); end
    for i in 1:3:n; delete!(s, boxes[i]); end
    push!(s, :sym); push!(s, "str"); push!(s, 1.5); push!(s, :sym); push!(s, boxes[2])
    order = 0
    for (k, x) in enumerate(s)
        v = x isa Base.RefValue{Int} ? x[] : x isa Symbol ? -1 : x isa String ? -2 : -3
        order = order * 31 + v * k
    end
    return (length(s), Ref(2) in s, boxes[2] in s, boxes[1] in s, :sym in s, 1.5 in s, order)
end
function idset_ints(n::Int)
    s = Base.IdSet{Int}()
    for i in 1:n; push!(s, i * 7); end
    for i in 1:2:n; pop!(s, i * 7); end
    acc = 0
    for x in s; acc = acc * 17 + x; end
    return (length(s), 14 in s, 7 in s, acc, isempty(s))
end
# deletions then insertions until the keys are compacted (`put_key` with holes, a full
# rehash of the index), and a missing key
function idset_churn(n::Int)
    s = Base.IdSet{Any}()
    vs = [[i] for i in 1:n]
    for v in vs; push!(s, v); end
    for round in 1:3, i in round:3:n
        delete!(s, vs[i])
        push!(s, [i, round])
    end
    acc = 0
    for x in s; acc = acc * 13 + sum(x::Vector{Int}); end
    k = try; pop!(s, [0]); 0; catch e; e isa KeyError ? 1 : 2; end
    return (length(s), vs[2] in s, acc, k)
end
function idset_ops(n::Int)
    a = Base.IdSet{Any}(Any[:a, :b, :c])
    b = copy(a)
    push!(b, :d); delete!(b, :a)
    u = union!(Base.IdSet{Any}(Any[:x]), b)
    e = empty!(copy(u))
    return (length(a), length(b), :a in a, :a in b, length(u), :x in u, length(e), :x in e)
end
const IDSET_IMAGE = Base.IdSet{Any}(Any[:a, :b, "c", 4, (1, 2), Int, nothing])
idset_image(k::Int) = ((:a in IDSET_IMAGE), (:z in IDSET_IMAGE), (k in IDSET_IMAGE), ((1, 2) in IDSET_IMAGE),
                       (Int in IDSET_IMAGE), (nothing in IDSET_IMAGE), length(IDSET_IMAGE))


# Base.TOML's parser: tables, nested and dotted tables, arrays of tables (IdSets of the
# defined tables), redefinition errors
const TOML_PROJECT = """
name = "Example"
uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
version = "0.5.4"

[deps]
JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"

[compat]
julia = "1.6"
JSON = "0.21"

[[pkg]]
name = "A"
git-tree-sha1 = "1234"

[[pkg]]
name = "B"
dep = "A"

[[pkg.sub]]
x = "1"

[extras.sub]
f = "x"
a.b.c = "deep"
"""
function toml_parse(k::Int)
    d = Base.TOML.parse(Base.TOML.Parser(TOML_PROJECT))
    deps = d["deps"]::Dict{String,Any}
    pk = d["pkg"]::Vector{Any}
    p2 = pk[2]::Dict{String,Any}
    sub = (d["extras"]::Dict{String,Any})["sub"]::Dict{String,Any}
    deep = ((sub["a"]::Dict{String,Any})["b"]::Dict{String,Any})["c"]::String
    return (length(d), length(deps), deps["JSON"]::String == "682c06a0-de6a-54ab-a142-c8b1cf79cde6",
            (d["compat"]::Dict{String,Any})["julia"]::String == "1.6", length(pk), p2["dep"]::String == "A",
            length(p2["sub"]::Vector{Any}), sub["f"]::String == "x", deep == "deep")
end
# a table defined twice is an error the parser finds through its IdSet of defined tables
function toml_redefined(k::Int)
    src = k == 1 ? "[a]\nx = \"1\"\n[a]\ny = \"2\"\n" : "[a]\nx = \"1\"\n[b]\ny = \"2\"\n"
    r = Base.TOML.tryparse(Base.TOML.Parser(src))
    return r isa Base.TOML.ParserError ? -1 : length(r::Dict{String,Any})
end

@testset "IdSet" begin
    @wtest idset_mixed(10)
    @wtest idset_mixed(400)
    @wtest idset_ints(1000)
    @wtest idset_ints(70000)
    @wtest idset_churn(50)
    @wtest idset_churn(600)
    @wtest idset_ops(1)
    @wtest idset_image(4)
    @wtest idset_image(5)
    @wtest idset_image_mutable(7)
    @wtest idset_image_mutable(100)
    @wtest idset_structure(260, 0)
    @wtest idset_structure(300, 5)
    @wtest idset_structure(400, 5)
    @wtest idset_structure(600, 2)
    @wtest idset_collide(20)
    @wtest idset_collide(40)
    @wtest idset_compact(20, 3)
    @wtest idset_compact(40, 20)
    @wtest toml_parse(1)
    @wtest toml_redefined(1)
    @wtest toml_redefined(2)
end
