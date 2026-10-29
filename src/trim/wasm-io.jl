# The pseudo-runtime's IO: Core's standard streams written through the host, in place of
# libuv (`jl_uv_puts`, `jl_uv_putb`, `jl_uv_putc`), which Wasm has no equivalent of. Applied
# with juliac's trim patches (see `patches.jl`); natively, `write_byte` still writes through
# libuv, so programs behave the same in the build process.

let CoreIO = Union{Core.CoreSTDOUT, Core.CoreSTDERR},
    write_byte = WasmCodegen.Runtime.IO.write_byte, flush_output = WasmCodegen.Runtime.IO.flush_output

    @eval Base begin
        core_fd(::Core.CoreSTDOUT) = Int32(1)
        core_fd(::Core.CoreSTDERR) = Int32(2)

        Core.write(io::$CoreIO, x::UInt8) = ($write_byte(core_fd(io), x); $flush_output(core_fd(io)); 1)
        function Core.write(io::$CoreIO, x::String)
            n = sizeof(x)
            for i in 1:n
                $write_byte(core_fd(io), codeunit(x, i))
            end
            $flush_output(core_fd(io))
            return n
        end
        function Core.print(io::$CoreIO, c::AbstractChar)
            u = reinterpret(UInt32, Char(c))
            $write_byte(core_fd(io), UInt8(u >> 24))
            for shift in (16, 8, 0)
                b = UInt8((u >> shift) & 0xff)
                b == 0x00 && break
                $write_byte(core_fd(io), b)
            end
            $flush_output(core_fd(io))
            return nothing
        end
        function Core.unsafe_write(io::$CoreIO, x::Ptr{UInt8}, nb::UInt)
            for i in 1:nb
                $write_byte(core_fd(io), unsafe_load(x, i))
            end
            $flush_output(core_fd(io))
            return nb
        end
        Core.unsafe_write(io::$CoreIO, x::Ptr{UInt8}, nb::Int) = (Core.unsafe_write(io, x, UInt(nb)); nb)

        write(io::$CoreIO, x::UInt8) = Core.write(io, x)
        write(io::$CoreIO, x::String) = Core.write(io, x)
        unsafe_write(io::$CoreIO, x::Ptr{UInt8}, nb::UInt) = Core.unsafe_write(io, x, nb)
    end
end
