// node --experimental-wasm-exnref check.mjs: parse the corpus of reference.json with the
// module and compare its output with the native parser's, node by node
import fs from 'node:fs';
const dir = new URL('.', import.meta.url).pathname;
const cases = JSON.parse(fs.readFileSync(dir + 'reference.json', 'utf8'));
const { instance } = await WebAssembly.instantiate(fs.readFileSync(dir + (process.argv[2] || 'parser.wasm')), {});
const e = instance.exports;
const enc = new TextEncoder(), dec = new TextDecoder();
const str = (len, byte) => dec.decode(Uint8Array.from({ length: len }, (_, j) => byte(j + 1)));
let bad = 0, nodes = 0, bytes = 0, time = 0;
for (const c of cases) {
  const src = enc.encode(c.src);
  e.src_resize(src.length);
  for (let i = 0; i < src.length; i++) e.src_set(i + 1, src[i]);
  const t0 = performance.now();
  const n = e.parse_src(1);
  time += performance.now() - t0;
  bytes += src.length;
  const errs = [];
  if (n !== c.out.length) errs.push(`${n} nodes, native ${c.out.length}`);
  for (let k = 1; k <= Math.min(n, c.out.length); k++) {
    const got = [e.out_kind(k), e.out_span(k), e.out_nodespan(k), e.out_class(k)];
    if (got.join() !== c.out[k - 1].join()) { errs.push(`node ${k}: ${got} native ${c.out[k - 1]}`); break; }
  }
  nodes += n;
  const nd = e.ndiag();
  if (nd !== c.diags.length) errs.push(`${nd} diagnostics, native ${c.diags.length}`);
  for (let k = 1; k <= Math.min(nd, c.diags.length); k++) {
    const msg = str(e.diag_msg_len(k), (j) => e.diag_msg_byte(k, j));
    const got = [e.diag_first(k), e.diag_last(k), e.diag_level(k), msg];
    if (got.join('|') !== c.diags[k - 1].join('|')) errs.push(`diagnostic ${k}: ${got.join('|')} native ${c.diags[k - 1].join('|')}`);
  }
  for (const [k, name] of Object.entries(c.names)) {
    const got = str(e.kind_name_len(+k), (j) => e.kind_name_byte(+k, j));
    if (got !== name) { errs.push(`kind ${k}: ${got} native ${name}`); break; }
  }
  if (errs.length) { bad++; console.log(`MISMATCH ${c.name}: ${errs.slice(0, 3).join('; ')}`); }
}
console.log(`${cases.length} sources, ${bytes} bytes, ${nodes} nodes: ${bad ? bad + ' mismatched' : 'all match'}; parsing took ${time.toFixed(1)} ms`);
process.exit(bad ? 1 : 0);
