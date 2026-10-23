add1(x::Int) = x + 1
fmuladd(a::Float64, b::Float64, c::Float64) = a * b + c
function loopsum(n::Int)
    s = 0.0
    for i in 1:n
        s += i
    end
    s
end
function halve(x::Float64)
    while x > 1.0
        x /= 2
    end
    x
end
collatz(n::Int) = (k = 0; while n != 1; n = iseven(n) ? n ÷ 2 : 3n + 1; k += 1; end; k)
sh(x::Int8, y::Int) = (x << y, x >> y, x >>> y)
narrow(x::UInt8, y::UInt8) = x + y
fact(n::Int) = n <= 1 ? 1 : n * fact(n - 1)
tup(x::Float64) = (x, 2x, Int(round(x)))
cmpf(x::Float64, y::Float64) = (x === y, isequal(x, y), x == y)
divs(a::Int, b::Int) = (div(a, b), rem(a, b))

@testset "basics" begin
    @wtest add1(41)
    @wtest fmuladd(1.5, 2.0, 0.25)
    @wtest loopsum(10)
    @wtest halve(1000.0)
    @wtest collatz(27)
    @wtest sh(Int8(-7), 3)
    @wtest sh(Int8(-7), 9)
    @wtest narrow(0xff, 0x02)
    @wtest fact(20)
    @wtest tup(2.6)
    @wtest cmpf(0.0, -0.0)
    @wtest cmpf(NaN, NaN)
    @wtest divs(-7, 2)
    @wtest divs(1, 0)
end

i128ops(a::Int64, b::Int64) = (x = Int128(a) * Int128(b) * 1000; (x + 1, x - 7, x * 3, x ÷ 7, x % 7, x < 0, x >> 70, x << 3, leading_zeros(x), Int64(x >> 64)))
u128div(a::UInt64, b::UInt64) = (x = UInt128(a) << 64 | b; (x ÷ UInt128(12345), x % UInt128(12345), x * x, count_ones(x)))
cmp_rational(x::Float64) = x < 1 // 10^5

@testset "int128" begin
    @wtest i128ops(123456789, -987654321)
    @wtest i128ops(-3, 7)
    @wtest u128div(0x0123456789abcdef, 0xfedcba9876543210)
    @wtest cmp_rational(1e-6)
    @wtest cmp_rational(1e-4)
end
