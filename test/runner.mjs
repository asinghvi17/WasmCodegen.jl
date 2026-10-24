// Persistent runner: NDJSON requests on stdin, one response per line.
// {id, wasm (base64) | wasmId, fn, args: [{t, bits}], results: [t...]}
import { createInterface } from 'node:readline';
const modules = new Map();
const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
let output = '';
let bytes = [];
const decoder = new TextDecoder();
// the host side of the runtime (import module "julia")
function makeImports(mod) {
  const julia = {
    write_byte: (fd, b) => { bytes.push(b); },
    entropy: () => {
      const w = new BigUint64Array(1);
      crypto.getRandomValues(w);
      return BigInt.asIntN(64, w[0]);
    },
    hrtime: () => BigInt(Math.round(performance.now() * 1e6)),
  };
  const imports = { julia };
  for (const imp of WebAssembly.Module.imports(mod)) {
    if (imp.module === 'julia' && !(imp.name in julia)) throw new Error('unknown host function ' + imp.name);
  }
  return imports;
}
function takeOutput() {
  output += decoder.decode(new Uint8Array(bytes));
  bytes = [];
  const o = output; output = ''; return o;
}
function decode(a) {
  const big = BigInt('0x' + a.bits);
  switch (a.t) {
    case 'i32': return Number(BigInt.asIntN(32, big));
    case 'i64': return BigInt.asIntN(64, big);
    case 'f32': { const b = new ArrayBuffer(4); new Uint32Array(b)[0] = Number(big); return new Float32Array(b)[0]; }
    case 'f64': { const b = new ArrayBuffer(8); new BigUint64Array(b)[0] = big; return new Float64Array(b)[0]; }
  }
  throw new Error('bad arg type ' + a.t);
}
function encode(t, v) {
  switch (t) {
    case 'i32': return (BigInt(v) & 0xffffffffn).toString(16);
    case 'i64': return BigInt.asUintN(64, v).toString(16);
    case 'f32': { const b = new ArrayBuffer(4); new Float32Array(b)[0] = v; return new Uint32Array(b)[0].toString(16); }
    case 'f64': { const b = new ArrayBuffer(8); new Float64Array(b)[0] = v; return new BigUint64Array(b)[0].toString(16); }
  }
  return 'ref';
}
rl.on('line', async (line) => {
  if (!line.trim()) return;
  const req = JSON.parse(line);
  try {
    let inst = modules.get(req.wasmId);
    if (!inst) {
      const bytes = Buffer.from(req.wasm, 'base64');
      const mod = await WebAssembly.compile(bytes, { builtins: ['js-string'] });
      inst = await WebAssembly.instantiate(mod, makeImports(mod));
      modules.set(req.wasmId, inst);
    }
    takeOutput();
    const f = inst.exports[req.fn];
    if (!f) throw new Error('no export ' + req.fn);
    let r;
    try {
      r = f(...req.args.map(decode));
    } catch (e) {
      process.stdout.write(JSON.stringify({ id: req.id, trap: String(e && e.message || e), output: takeOutput() }) + '\n');
      return;
    }
    const rs = req.results.length === 1 ? [r] : (req.results.length === 0 ? [] : r);
    const results = req.results.map((t, i) => encode(t, rs[i]));
    process.stdout.write(JSON.stringify({ id: req.id, results, output: takeOutput() }) + '\n');
  } catch (e) {
    process.stdout.write(JSON.stringify({ id: req.id, error: String(e && e.stack || e) }) + '\n');
  }
});
process.stdout.write(JSON.stringify({ ready: true }) + '\n');
