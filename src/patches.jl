# Patches: methods of Base and the standard library redefined for trimmed programs, as
# juliac redefines them in its build process (`src/trim/`, from JuliaC.jl).
#
# They are real method definitions, not overlays: native inference, concrete evaluation
# and effects treat them as the methods they replace, so the code compiled is the code
# juliac compiles. To keep them from affecting the session, they are defined in a new world
# for the compilation only: the program is inferred in that world, while the compiler runs
# in the world before them, and they are deleted afterwards (deleting a method that
# replaced another restores it).

const TRIM_PATCHES = [joinpath(@__DIR__, "trim", "juliac-trim-base.jl"),
                      joinpath(@__DIR__, "trim", "juliac-trim-stdlib.jl"),
                      # the pseudo-runtime: what Wasm has no C runtime for
                      joinpath(@__DIR__, "trim", "wasm-base.jl"),
                      joinpath(@__DIR__, "trim", "wasm-io.jl"),
                      joinpath(@__DIR__, "trim", "wasm-paths.jl"),
                      joinpath(@__DIR__, "trim", "wasm-random.jl"),
                      joinpath(@__DIR__, "trim", "wasm-memory.jl")]

# the constants the patches rebind (methods are restored by deleting their replacements)
const PATCHED_CONSTS = [(Base, :invokelatest)]

"""
The world the compiler runs in: the world when WasmCodegen was loaded. The compiler's
own (native) code is compiled for that world and stays valid there whatever is defined
or deleted later (the patches, the program, packages loaded after WasmCodegen), as
GPUCompiler isolates the compiler from the code it compiles. Programs are inferred in
the latest world.
"""
const COMPILER_WORLD = Ref{UInt}(typemax(UInt))

"Whether a session of patches is open (see `with_trim_patches`)."
const IN_PATCH_SESSION = Ref(false)

latest_global(m::Module, s::Symbol) = Base.invoke_in_world(Base.get_world_counter(), getglobal, m, s)

"""
    with_trim_patches(f; patches=TRIM_PATCHES)

Define the patches in a new world, call `f(compiler_world, program_world)` in the world
before them (`compiler_world`), and remove them afterwards. The program is to be inferred
in `program_world`, where the patches are defined.

Compilations within `f` (calls of [`compile`](@ref)) share the patches: their programs
are inferred in the latest world (with the patches, and whatever `f` defined) and the
compiler runs in `compiler_world`. Defining and deleting the patches invalidates code
that depends on the methods they replace, so a session of several compilations is much
faster than patching each one (as juliac builds in one process).
"""
function with_trim_patches(f; patches=TRIM_PATCHES)
    IN_PATCH_SESSION[] && return f(COMPILER_WORLD[], Base.get_world_counter())
    w0 = Base.get_world_counter()
    consts = [(m, s, getglobal(m, s)) for (m, s) in PATCHED_CONSTS]
    sandbox = Module(:WasmCodegenTrimPatches)
    added = Method[]
    try
        Core.eval(sandbox, :(Core.Compiler._verify_trim_world_age[] = $w0))
        Core.eval(sandbox, :(const WasmCodegen = $(@__MODULE__)))
        for file in patches
            Base.include(sandbox, file)
        end
        w1 = Base.get_world_counter()
        Base.visit(Core.methodtable) do m
            w0 < m.primary_world <= w1 && push!(added, m)
        end
        IN_PATCH_SESSION[] = true
        return f(COMPILER_WORLD[], w1)
    finally
        IN_PATCH_SESSION[] = false
        foreach(Base.delete_method, added)
        # (the binding as of now: this code runs in the world before the patches)
        for (m, s, v) in consts
            latest_global(m, s) === v || Core.eval(m, :(const $s = $v))
        end
    end
end
