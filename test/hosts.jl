# The host interfaces (`Config(host = ...)`, src/host.jl): the module's imports for each,
# output (both streams, in order, and more than WASI's buffer holds), entropy and the
# clock, run by the test runner (js/julia.mjs for `:js`, Node's WASI for `:wasi`), and
# WASI modules run by js/julia.mjs's own WASI functions (hosts without WASI).

host_print(n::Int) = (println(Core.stdout, "out ", n); println(Core.stderr, "err ", 2n); print(Core.stdout, 'λ', "\n"); n)
host_big_print(n::Int) = (print(Core.stdout, repeat("ab", n)); n)
host_entropy_time() = (t0 = time_ns(); x = rand(); t1 = time_ns(); (0.0 <= x < 1.0, t1 >= t0))

imported_modules(c) = unique(f.imported[1] for f in c.cgm.mod.funcs if f.imported !== nothing)
exported_names(c) = [name for (name, _) in c.cgm.mod.exports]

# run `fn(args...)` of the module with js/julia.mjs's `instantiate`: (result as a string, output)
function run_julia_mjs(c, fn, args...)
    dir = mktempdir()
    write(joinpath(dir, "m.wasm"), c.bytes)
    host = joinpath(pkgdir(WasmCodegen), "js", "julia.mjs")
    write(joinpath(dir, "run.mjs"), """
    import { instantiate } from '$(host)';
    import fs from 'node:fs';
    const out = [];
    const { instance } = await instantiate(fs.readFileSync('$(joinpath(dir, "m.wasm"))'), { write: (fd, b) => out.push(...b) });
    const r = instance.exports.$fn($(join((a isa Int64 ? "$(a)n" : string(a) for a in args), ", ")));
    process.stdout.write(JSON.stringify({ r: String(r), out: new TextDecoder().decode(new Uint8Array(out)) }));
    """)
    resp = JSON.parse(read(`$(node_cmd()) $(joinpath(dir, "run.mjs"))`, String))
    return String(resp["r"]), String(resp["out"])
end

@testset "host interfaces" begin
    for host in (:js, :wasi)
        cfg = WasmCodegen.Config(; host)
        printing = WasmCodegen.compile(host_print, (Int,); config=cfg)
        entropy = WasmCodegen.compile(host_entropy_time, (); config=cfg)
        if host === :js
            @test imported_modules(printing) == ["julia"]
            @test !("memory" in exported_names(printing))
        else
            @test imported_modules(printing) == imported_modules(entropy) == ["wasi_snapshot_preview1"]
            @test "memory" in exported_names(printing)
            # the RNG's seed from the host: initialization once the instance is made
            @test "_initialize" in exported_names(entropy)
        end
        @test wasm_run(printing, "host_print", 3; rettype=Int) == 3
        @test LAST_OUTPUT[] == "out 3\nerr 6\nλ\n"
        big = WasmCodegen.compile(host_big_print, (Int,); config=cfg)
        @test wasm_run(big, "host_big_print", 50_000; rettype=Int) == 50_000
        @test LAST_OUTPUT[] == repeat("ab", 50_000)
        @test wasm_run(entropy, "host_entropy_time"; rettype=Tuple{Bool,Bool}) == (true, true)
        # js/julia.mjs runs either kind (for WASI, its own WASI functions)
        @test run_julia_mjs(printing, "host_print", 4) == ("4", "out 4\nerr 8\nλ\n")
        @test run_julia_mjs(big, "host_big_print", 40_000) == ("40000", repeat("ab", 40_000))
    end
    @test_throws ArgumentError WasmCodegen.compile(host_print, (Int,); config=WasmCodegen.Config(host=:wasm))
end
