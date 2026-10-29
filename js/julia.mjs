// The JavaScript host of modules compiled by WasmCodegen (src/host.jl). A module compiled
// with `Config(host = :js)` (the default) imports the functions of the module "julia"; one
// compiled with `host = :wasi` imports WASI preview 1 ("wasi_snapshot_preview1"), which
// WASI runtimes (wasmtime, wasmer, Node's node:wasi) provide, and which this file provides
// too, the part the modules use, for hosts without it (browsers).
//
//   import { instantiate } from './julia.mjs';
//   const { instance } = await instantiate(bytes);   // the module's output to the console
//   instance.exports.f(1.0);
//
// Options: `write(fd, bytes)` receives the module's output (fd 1: stdout, 2: stderr), a
// Uint8Array of UTF-8; by default it is written to the console line by line.

const WASI_EBADF = 8, WASI_EINVAL = 28;

// writes to the console, a line at a time, in the order written: an unfinished line is
// written when the other stream is written to, and by `flush()`
function consoleWriter() {
  const decoder = new TextDecoder();
  let fd = 1, buf = [];
  const emit = () => {
    (fd === 2 ? console.error : console.log)(decoder.decode(new Uint8Array(buf)));
    buf = [];
  };
  const write = (to, bytes) => {
    if (to !== fd) { if (buf.length) emit(); fd = to; }
    for (const b of bytes) {
      if (b === 10) emit();
      else buf.push(b);
    }
  };
  write.flush = () => { if (buf.length) emit(); };
  return write;
}

// the host clocks, in nanoseconds: monotonic, and since the Unix epoch
const monotonicNs = () => BigInt(Math.round(performance.now() * 1e6));
const realtimeNs = () => BigInt(Math.round((performance.timeOrigin + performance.now()) * 1e6));

function fillRandom(bytes) {
  // getRandomValues fills at most 65536 bytes at a time
  for (let i = 0; i < bytes.length; i += 65536) crypto.getRandomValues(bytes.subarray(i, i + 65536));
}

/**
 * The imports of a module (both interfaces), to instantiate it with:
 * `{ imports, attach(instance), flush() }`. For a WASI module (one exporting its memory),
 * `attach` gives the WASI functions the instance's memory and runs its initialization
 * (`_initialize`), as WASI hosts do; a JavaScript module initializes as it is instantiated.
 */
export function createHost({ write } = {}) {
  const out = write ?? consoleWriter();
  let memory = null;
  const view = () => new DataView(memory.buffer);
  const julia = {
    write_byte: (fd, b) => out(fd, Uint8Array.of(b)),
    entropy: () => {
      const w = new BigUint64Array(1);
      crypto.getRandomValues(w);
      return BigInt.asIntN(64, w[0]);
    },
    hrtime: monotonicNs,
    // seconds since the Unix epoch, to the microsecond (as gettimeofday's)
    clock_now: () => {
      const t = realtimeNs();
      return Number(t / 1000000000n) + Number((t % 1000000000n) / 1000n) * 1e-6;
    },
  };
  const wasi = {
    fd_write(fd, iovs, iovsLen, nwrittenPtr) {
      if (fd !== 1 && fd !== 2) return WASI_EBADF;
      const v = view();
      let n = 0;
      for (let i = 0; i < iovsLen; i++) {
        const ptr = v.getUint32(iovs + 8 * i, true), len = v.getUint32(iovs + 8 * i + 4, true);
        out(fd, new Uint8Array(memory.buffer, ptr, len).slice());
        n += len;
      }
      v.setUint32(nwrittenPtr, n, true);
      return 0;
    },
    random_get(ptr, len) {
      fillRandom(new Uint8Array(memory.buffer, ptr, len));
      return 0;
    },
    clock_time_get(id, precision, ptr) {
      const t = id === 0 ? realtimeNs() : id === 1 ? monotonicNs() : null;
      if (t === null) return WASI_EINVAL;
      view().setBigUint64(ptr, t, true);
      return 0;
    },
  };
  return {
    imports: { julia, wasi_snapshot_preview1: wasi },
    attach(instance) {
      if (!(instance.exports.memory instanceof WebAssembly.Memory)) return;
      memory = instance.exports.memory;
      instance.exports._initialize?.();
    },
    flush() { out.flush?.(); },
  };
}

/**
 * Compile (from bytes or a Response) and instantiate a module with this host:
 * `{ module, instance, host }`.
 */
export async function instantiate(source, options = {}) {
  const module = source instanceof WebAssembly.Module ? source :
    typeof Response !== 'undefined' && source instanceof Response ? await WebAssembly.compileStreaming(source) :
    await WebAssembly.compile(source);
  const host = createHost(options);
  const instance = await WebAssembly.instantiate(module, host.imports);
  host.attach(instance);
  return { module, instance, host };
}
