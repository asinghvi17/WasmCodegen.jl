# The driver: from entry points to a module.

"""
    Entry(f, argtypes; name)

An entry point of a module: the function `f` called with arguments of types `argtypes`,
exported as `name`.
"""
struct Entry
    f::Any
    argtypes::Tuple
    name::String
end
Entry(f, argtypes::Tuple; name::AbstractString=string(nameof(f))) = Entry(f, argtypes, String(name))

"""
    Compilation

The result of a compilation: the module's bytes, the closed world, the code generator's
state (for inspection) and its diagnostics.
"""
struct Compilation
    bytes::Vector{UInt8}
    world::ClosedWorld
    cgm::CGModule
end

"""
    compile(entries; config=Config(), validate=true) -> Compilation

Compile the entry points (`Entry`s, or `(f, argtypes)` tuples) and everything they call
to a WebAssembly module, as juliac compiles a program: the closed world of the entry
points is collected, compiled, and the objects it refers to are serialized into the
module.
"""
function compile(entries::Vector; config::Config=Config(), validate::Bool=true,
                 world::Union{Nothing,UInt}=nothing)
    entries = Entry[e isa Entry ? e : Entry(e[1], e[2]) for e in entries]
    run(program_world) = Base.invoke_in_world(COMPILER_WORLD[], compile_in_world, entries,
                                              config, validate, program_world)
    if config.trim_patches && world === nothing
        # the program in the latest world, with juliac's patches
        return with_trim_patches() do _, _
            run(Base.get_world_counter())
        end
    end
    return run(something(world, Base.get_world_counter()))
end

function compile_in_world(entries::Vector{Entry}, config::Config, validate::Bool, world::UInt)
    mis = Core.MethodInstance[entry_instance(e.f, e.argtypes; world) for e in entries]
    w = collect_world(mis; world, verify=config.verify)
    cgm = CGModule(w, config)
    for (e, mi) in zip(entries, mis)
        info = get_function!(cgm, mi)
        add_export!(cgm.mod, e.name, info.func)
    end
    process_worklist!(cgm)
    finish_module!(cgm)
    bytes = to_bytes(cgm.mod)
    validate && WasmBuilder.validate(bytes)
    return Compilation(bytes, w, cgm)
end

compile(f, argtypes::Tuple; kw...) = compile([Entry(f, argtypes)]; kw...)

function finish_module!(cgm::CGModule)
    finish_types!(cgm)
    finish_image!(cgm)
end
