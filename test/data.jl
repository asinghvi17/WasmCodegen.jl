struct Point
    x::Float64
    y::Float64
end
mutable struct Counter
    n::Int
    total::Float64
end
norm2(p::Point) = sqrt(p.x^2 + p.y^2)
mkpoint(x::Float64) = norm2(Point(x, 2x))
function counter(n::Int)
    c = Counter(0, 0.0)
    for i in 1:n
        c.n += 1
        c.total += i / 2
    end
    c.total
end
function vec_sum(n::Int)
    v = Float64[]
    for i in 1:n
        push!(v, i * 0.5)
    end
    sum(v)
end
function vec_bcast(n::Int)
    v = collect(1.0:n)
    w = v .* 2 .+ 1
    w[end] + length(w)
end
function vec_sort(n::Int)
    v = [mod(i * 7919, 101) for i in 1:n]
    sort!(v)
    v[1] + 1000 * v[end]
end
function closure_sum(a::Float64, n::Int)
    f = x -> x * a
    s = 0.0
    for i in 1:n
        s += f(i)
    end
    s
end
mat_trace(n::Int) = (A = zeros(n, n); for i in 1:n; A[i, i] = i; end; sum(A))
tuple_dyn(i::Int) = (1.5, 2.5, 3.5, 4.5)[i]

# the image: constants and global variables
const TABLE = [1.0, 2.0, 4.0, 8.0, 16.0]
const BIGTABLE = collect(1.0:1000.0)
table_lookup(i::Int) = TABLE[i] + BIGTABLE[i * 100]
const NAMES = (:a, :b, :c)
pick(i::Int) = NAMES[i] === :b
mutable struct Node
    val::Int
    next::Union{Nothing,Node}
end
const RING = let a = Node(1, nothing), b = Node(2, a), c = Node(3, b)
    a.next = c
    a
end
function ring_walk(k::Int)
    n = RING
    s = 0
    for _ in 1:k
        s += n.val
        n = n.next::Node
    end
    s
end
const SHARED = [1, 2, 3]
const PAIR = (SHARED, SHARED)
shared_identity() = PAIR[1] === PAIR[2]
counter_global = 0
function bump(k::Int)
    global counter_global
    for _ in 1:k
        counter_global += 1
    end
    counter_global
end

@testset "data" begin
    @wtest mkpoint(1.5)
    @wtest counter(10)
    @wtest vec_sum(100)
    @wtest vec_bcast(10)
    @wtest vec_sort(50)
    @wtest closure_sum(1.5, 10)
    @wtest mat_trace(4)
    @wtest tuple_dyn(3)
end

@testset "image" begin
    @wtest table_lookup(3)
    @wtest pick(2)
    @wtest ring_walk(7)
    @wtest shared_identity()
end
