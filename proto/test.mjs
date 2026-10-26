import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { load, ProgramError } from './build/lorenz/lorenz.mjs';

const native = JSON.parse(await readFile(new URL('./build/lorenz/julia.json', import.meta.url)));
const { Handle, raw } = await load();
assert.deepEqual(Object.keys(raw).sort(), ['create', 'destroy', 'point', 'solve']);
const a = new Handle(), b = new Handle();
assert.notEqual(a.handle, b.handle);
assert.equal(typeof a.handle, 'bigint');
const absoluteTolerance = 1e-7, relativeTolerance = 1e-8;
let maxAbsoluteError = 0, comparisons = 0;
const wasmPoints = [];
for (const [s, reference] of [[a, native[0]], [b, native[1]]]) {
  assert.equal(s.solve(...reference.parameters), reference.count);
  const points = [];
  for (let i = 1; i <= reference.count; ++i) {
    const row = [];
    for (let k = 1; k <= 3; ++k) {
      const actual = s.point(i, k), expected = reference.points[i - 1][k - 1];
      const error = Math.abs(actual - expected);
      maxAbsoluteError = Math.max(maxAbsoluteError, error);
      assert.ok(error <= absoluteTolerance + relativeTolerance * Math.abs(expected),
        `point(${i},${k}): ${actual} versus ${expected}`);
      comparisons++; row.push(actual);
    }
    points.push(row);
  }
  wasmPoints.push(points);
}
await writeFile(new URL("./build/lorenz/wasm-points.json", import.meta.url),JSON.stringify(wasmPoints));
assert.ok(Math.abs(a.point(101, 1) - b.point(101, 1)) > 0.1);
// b's solve must not change a's state (already checked a before solving b).
assert.ok(Math.abs(a.point(101, 1) - native[0].points[100][0]) < absoluteTolerance);

// Make reset observable: the retired slot's last initial x must differ from default.
assert.equal(a.solve(10, 28, 8 / 3, 2), native[0].count);
assert.equal(a.point(1, 1), 2);
const stale = a.handle;
a.destroy();
assert.deepEqual(raw.point(stale, 1, 1), [-1, 0]);
assert.deepEqual(raw.solve(stale, ...native[0].parameters), [-1, 0]);
assert.deepEqual(raw.destroy(stale), [-1, 0]);
assert.deepEqual(raw.point(0n, 1, 1), [-1, 0]);
assert.deepEqual(raw.point(0x100000005n, 1, 1), [-1, 0]); // out-of-pool slot
assert.deepEqual(raw.point(1n, 1, 1), [-1, 0]); // zero generation
assert.deepEqual(raw.point(0x200000002n, 1, 1), [-1, 0]); // wrong generation
assert.throws(() => a.point(1, 1), e => e instanceof ProgramError && e.status === -1);

const c = new Handle();
assert.notEqual(c.handle, stale);
assert.equal(c.handle & 0xffffffffn, stale & 0xffffffffn); // reuse same slot
assert.deepEqual(raw.point(stale, 1, 1), [-1, 0]);
assert.equal(c.point(1, 1), 1); // reset cleared a's solved trajectory
assert.equal(c.point(1, 2), 1);
const d = new Handle(), e = new Handle();
assert.deepEqual(raw.create(), [-2, 0n]);
assert.throws(() => new Handle(), e => e instanceof ProgramError && e.status === -2);
for (const s of [b, c, d, e]) s.destroy();
const again = new Handle();
again.destroy();

// A distinct Wasm module instance owns a distinct state graph and free-slot table.
const other = await load();
const fresh = new other.Handle();
assert.equal(fresh.point(1, 1), 1);
fresh.destroy();

const result = { node: process.version, comparisons, maxAbsoluteError,
  absoluteTolerance, relativeTolerance, lifecycle: 'passed', isolation: 'passed' };
await writeFile(new URL('./results/node-results.json', import.meta.url), JSON.stringify(result));
console.log(JSON.stringify(result));
