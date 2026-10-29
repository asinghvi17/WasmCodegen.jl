# The calls into Julia's C runtime that the runtime answers with functions of its own
# (`runtime/jlapi.jl`), added to `RUNTIME_CCALLS` (see `foreigncall.jl`).

for (name, f, kinds) in (
        # IdSet (`Base.IdSet`; Base.TOML's parser and printer)
        (:jl_idset_peek_bp, Runtime.IdSets.peek_bp, [:val, :val, :val]),
        (:jl_idset_pop, Runtime.IdSets.pop, [:val, :val, :val]),
        (:jl_idset_put_key, Runtime.IdSets.put_key, [:val, :val, :val]),
        (:jl_idset_put_idx, Runtime.IdSets.put_idx, [:val, :val, :val]))
    RUNTIME_CCALLS[name] = RuntimeCcall(f, kinds)
end
