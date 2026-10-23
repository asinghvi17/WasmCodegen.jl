"""
    WasmCodegen

A compiler of Julia programs to WebAssembly (with the GC proposal), working like juliac:
from entry points, the closed world of code they run is collected with Julia's own
inference, structured (IRStructurizer.jl), compiled to Wasm (WasmBuilder.jl), and the
objects it refers to are serialized into the module.
"""
module WasmCodegen

using WasmBuilder
using WasmBuilder: Inst, Func, Global, WModule, TypeRef, RefType, ValType, StorageType,
                   PackedType, FieldType, StructType, ArrayType, SubType, Builder, emit!,
                   typedef, is_unreachable
import IRStructurizer
using IRStructurizer: StructuredIRCode
using CompilerCaching: StackedMethodTable

const CC = Base.Compiler

include("errors.jl")
include("interpreter.jl")
include("collect.jl")
include("prepare.jl")
include("layout.jl")
include("values.jl")
include("context.jl")
include("emit.jl")
include("builtins.jl")
include("memory.jl")
include("intrinsics.jl")
include("foreigncall.jl")
include("image.jl")
include("overlays.jl")
include("types_runtime.jl")
include("patches.jl")
include("driver.jl")

export compile, Entry, Config

function __init__()
    COMPILER_WORLD[] = Base.get_world_counter()
end

end
