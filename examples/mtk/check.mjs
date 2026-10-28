// node --experimental-wasm-exnref check.mjs: solve the reference case in the module and
// compare with the native run recorded by build.jl (stats.txt)
import fs from 'node:fs';
import { instantiate } from '../../js/julia.mjs';
const dir = new URL('.', import.meta.url).pathname;
const stats = Object.fromEntries(fs.readFileSync(dir + 'stats.txt', 'utf8').trim().split('\n').map((l) => l.split('=')));
const bytes = fs.readFileSync(dir + (process.argv[2] || "oscillator.wasm"));
const mod = await WebAssembly.compile(bytes);
console.log('imports:', JSON.stringify(WebAssembly.Module.imports(mod)));
const { instance: { exports: e } } = await instantiate(mod);
const n = e.osc_solve(1.0, 10.0, 0.5, 1.0, 2.0, 1.0, 0.0);
const got = { x: e.osc_state(n, 1), v: e.osc_state(n, 2), E: e.osc_observed(n, 1), steps: e.osc_steps(), points: n };
let best = Infinity;
for (let r = 0; r < 20; r++) {
  const t0 = performance.now();
  e.osc_solve(1.0, 10.0, 0.5, 1.0, 2.0, 1.0, 0.0);
  best = Math.min(best, performance.now() - t0);
}
console.log('wasm:  ', got, `solve ${best.toFixed(2)} ms`);
console.log('native:', { x: +stats.x, v: +stats.v, E: +stats.E, steps: +stats.steps, points: +stats.points },
            `solve ${(+stats.native_ms).toFixed(2)} ms`);
const ok = got.steps === +stats.steps && got.points === +stats.points &&
  ['x', 'v', 'E'].every((k) => Math.abs(got[k] - stats[k]) <= 1e-9 * Math.max(1, Math.abs(stats[k])));
console.log(ok ? 'match' : 'MISMATCH');
process.exit(ok ? 0 : 1);
