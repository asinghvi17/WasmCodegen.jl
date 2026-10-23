# Output: the one primitive the pseudo-runtime's IO (`trim/wasm-io.jl`) writes through, a
# host import (`julia.write_byte(fd, byte)`, which the code generator compiles calls of
# `write_byte` to). The host buffers bytes and decodes them as UTF-8.

module IO

"Write the byte `b` to the file descriptor `fd` (1: stdout, 2: stderr): a host call."
@noinline function write_byte(fd::Int32, b::UInt8)
    stream = fd == Int32(1) ? Core.io_pointer(Core.stdout) : Core.io_pointer(Core.stderr)
    ccall(:jl_uv_putb, Cvoid, (Ptr{Cvoid}, UInt8), stream, b)
    return nothing
end

end
