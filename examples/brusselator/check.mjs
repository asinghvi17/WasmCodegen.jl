// node check.mjs [brusselator.wasm]: solve with each linear solver, print the counts, the
// time and a checksum of the solution (native.jl prints the same for native Julia)
import fs from 'node:fs';
const bytes = fs.readFileSync(process.argv[2] ?? new URL('brusselator.wasm', import.meta.url));
const julia = {
  write_byte: () => {},
  entropy: () => 0n,
  hrtime: () => BigInt(Math.round(performance.now() * 1e6)),
};
const { instance } = await WebAssembly.instantiate(bytes, { julia });
const e = instance.exports;
const names = ['GenericLUFactorization', 'PureKLUFactorization', 'KrylovJL_GMRES'];
const N = e.bz_n();
for (let k = 1; k <= 3; k++) {
  let n = e.bz_solve(k, 1.0, 3.0, 0.02, 1.0);
  const reps = 10;
  const t0 = performance.now();
  for (let r = 0; r < reps; r++) n = e.bz_solve(k, 1.0, 3.0, 0.02, 1.0);
  const ms = (performance.now() - t0) / reps;
  let sum = 0;
  for (let i = 1; i <= n; i++) for (let j = 1; j <= N; j++) sum += e.bz_value(k, i, j, 1) + 2 * e.bz_value(k, i, j, 2);
  const st = [1, 2, 3, 5].map(s => e.bz_stat(k, s));
  console.log(`${names[k - 1].padEnd(24)}points ${n}, steps ${st[0]}+${st[1]}, W ${st[2]}, solves ${st[3]}, ` +
              `${ms.toFixed(2)} ms, checksum ${sum.toPrecision(12)}`);
}
