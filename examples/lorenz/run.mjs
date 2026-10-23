// node run.mjs lorenz.wasm: solve, read the trajectory, compare a point, time it
import fs from 'node:fs';
const bytes = fs.readFileSync(process.argv[2]);
const { instance } = await WebAssembly.instantiate(bytes, {});
const e = instance.exports;
let n = e.lorenz_solve(10, 28, 8 / 3, 1);
console.log('points', n, 'steps', e.lorenz_steps(), 'last x', e.lorenz_point(n, 1));
const reps = 20;
let t0 = performance.now();
for (let r = 0; r < reps; r++) n = e.lorenz_solve(10 + r * 0.01, 28, 8 / 3, 1);
let t1 = performance.now();
console.log(`solve: ${((t1 - t0) / reps).toFixed(2)} ms`);
t0 = performance.now();
let s = 0;
for (let i = 1; i <= n; i++) s += e.lorenz_point(i, 1) + e.lorenz_point(i, 3);
t1 = performance.now();
console.log(`read ${n} points: ${(t1 - t0).toFixed(2)} ms`);
