# Hash and printing of the tuples of a VersionNumber's prerelease and build fields
# (`Tuple{Vararg{Union{UInt64,String}}}`): Base's `hash(t::Tuple, h)` recurses through
# `tail(t)`, a splat of a tuple of unknown length. The same fold as a loop, from the last
# element: `hash(t[1], hash(t[2], ... hash(t[n], hash((), h))))`, so the hashes (and Dicts
# keyed by VersionNumbers, as the resolver's) are the native ones. Applied with juliac's trim
# patches (see `patches.jl`).

@eval Base function hash(t::Tuple{Vararg{Union{UInt64,String}}}, h::UInt)
    h = hash((), h)
    for i in length(t):-1:1
        h = hash(t[i], h)
    end
    return h
end

# Printing and hashing a VersionNumber: Base's pass the parts to functions (`join`, `hash` of a
# tuple), calls juliac's verifier cannot resolve (a tuple of unknown length is not specialized
# on), and whose specializations may take them as a `Tuple` (elements of type `Any`). The same
# text and hash, the parts handled by loops in place (`length` and indexing of the tuple only).
@eval Base begin
    function print(io::IO, v::VersionNumber)
        # (the constant, not `typemax(VersionNumber)`, whose constructor checks its parts with a Regex)
        v == $(typemax(VersionNumber)) && return print(io, "∞")
        print(io, v.major)
        print(io, '.')
        print(io, v.minor)
        print(io, '.')
        print(io, v.patch)
        pre = v.prerelease
        if length(pre) > 0
            print(io, '-')
            for i in 1:length(pre)
                i > 1 && print(io, '.')
                x = pre[i]
                x isa String ? print(io, x) : print(io, x::UInt64)
            end
        end
        build = v.build
        if length(build) > 0
            print(io, '+')
            for i in 1:length(build)
                i > 1 && print(io, '.')
                x = build[i]
                x isa String ? print(io, x) : print(io, x::UInt64)
            end
        end
    end
    function hash(v::VersionNumber, h::UInt)
        # (as this Julia's Base mixes in the seed)
        h = VERSION >= v"1.13-" ? h ⊻ (0x8ff4ffdb75f9fede % UInt) : h + (0x8ff4ffdb75f9fede % UInt)
        h = hash(v.major, h)
        h = hash(v.minor, h)
        h = hash(v.patch, h)
        # hash(v.prerelease, ~h), hash(v.build, ~h): Base's fold of a tuple, from its last element
        h = hash((), ~h)
        pre = v.prerelease
        for i in length(pre):-1:1
            x = pre[i]
            h = x isa String ? hash(x, h) : hash(x::UInt64, h)
        end
        h = hash((), ~h)
        build = v.build
        for i in length(build):-1:1
            x = build[i]
            h = x isa String ? hash(x, h) : hash(x::UInt64, h)
        end
        return h
    end
end
