# Output: the primitives the pseudo-runtime's IO (`trim/wasm-io.jl`) writes through, which
# the code generator compiles to the host's (`host.jl`): `write_byte(fd, byte)`, and
# `flush_output(fd)` once a write is complete (the bytes so far written out, where the
# module buffers them).

module IO

"Write the byte `b` to the file descriptor `fd` (1: stdout, 2: stderr): a host call."
@noinline function write_byte(fd::Int32, b::UInt8)
    stream = fd == Int32(1) ? Core.io_pointer(Core.stdout) : Core.io_pointer(Core.stderr)
    ccall(:jl_uv_putb, Cvoid, (Ptr{Cvoid}, UInt8), stream, b)
    return nothing
end

"The end of a write to `fd`: what was written is written out (a host call)."
@noinline function flush_output(fd::Int32)
    stream = fd == Int32(1) ? Core.io_pointer(Core.stdout) : Core.io_pointer(Core.stderr)
    ccall(:jl_uv_flush, Cvoid, (Ptr{Cvoid},), stream)
    return nothing
end

end
