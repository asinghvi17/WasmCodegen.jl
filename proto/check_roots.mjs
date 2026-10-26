import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
for (const [path,root] of [['roots.wasm',false],['roots-entry.wasm',true]]) {
  const {instance:{exports:e}}=await WebAssembly.instantiate(await readFile(new URL('./build/'+path,import.meta.url)));
  assert.equal('root' in e,root); assert.ok(!('private_helper' in e));
  if(root) assert.equal(e.root(2),26);
  const [status,h]=e.create(); assert.equal(status,0);
  assert.deepEqual(e.value(h,2),[0,14]);
  assert.deepEqual(e.high32(h),[0,-1]);
  assert.deepEqual(e.high64(h),[0,-1n]);
}
const {load}=await import('./build/counter.mjs');
const {Handle}=await load(); const h=new Handle();
assert.equal(h.high32(),0xffffffff); assert.equal(h.high64(),0xffffffffffffffffn);
assert.equal(h.lookup(2),14); h.destroy();
console.log('Wasm private callees, root exports, unsigned loader normalization passed');
