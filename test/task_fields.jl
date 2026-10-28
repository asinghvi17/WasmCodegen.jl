# The module's task starts as the root task does natively: `nothing` in the fields
# `jl_init_root_task` sets, so `task_local_storage` creates and finds its table, and `code` undefined.
function tls_counter(n::Int)
    key = :wasmcodegen_test_tls_key
    task_local_storage(key, Ref(0))
    for i in 1:n
        (task_local_storage(key)::Base.RefValue{Int})[] += i
    end
    return (task_local_storage(key)::Base.RefValue{Int})[]
end

root_task_fields() = (t = current_task();
    (map(k -> getfield(t, k) === nothing, (:next, :queue, :storage, :donenotify, :result, :scope))...,
     isdefined(t, :code)))

@testset "task-local storage" begin
    @wtest tls_counter(10)
    c = wcompile(root_task_fields, ())
    @test wasm_run(c, "root_task_fields"; rettype = NTuple{7,Bool}) == (true, true, true, true, true, true, false)
end
