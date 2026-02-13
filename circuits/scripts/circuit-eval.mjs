// circuits/scripts/circuit-eval.mjs
//
// Outputs are ALWAYS base64 (ASCII), so Foundry vm.ffi won't choke.
//
// Usage examples:
//
// 1) StorageHashBytes32Test(3) wrapper (outBytes[32]):
//    node circuits/scripts/circuit-eval.mjs storageHashBytes32 '{"ilo":[10,20,0],"ihi":[11,21,0],"op":[1,2,0]}'
//
// 2) PubInputsMasked wrapper where main.pubInput0 is the output field element / u256:
//    node circuits/scripts/circuit-eval.mjs pubInput0_u256 '{"oldRootF":"123", ... }'
//
// Notes:
// - The JSON must match the circuit input signal names.
// - For array inputs, pass JS arrays (numbers or strings).
// - For big field elements, pass strings (decimal) to avoid JS precision loss.

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);

// -------------------------------
// CJS interop for witness_calculator.js
// -------------------------------
function ensureCjs(wcalcJsPath) {
  const absJs = path.resolve(wcalcJsPath);
  if (!fs.existsSync(absJs)) throw new Error(`witness_calculator.js not found: ${absJs}`);

  const absCjs = absJs.replace(/\.js$/, ".cjs");
  if (!fs.existsSync(absCjs)) fs.copyFileSync(absJs, absCjs);

  return absCjs;
}

async function calcWitnessArray(wasmPath, wcalcJsPath, input) {
  const cjsPath = ensureCjs(wcalcJsPath);
  const mod = require(cjsPath);

  const factory =
    (typeof mod === "function" ? mod :
     typeof mod?.default === "function" ? mod.default :
     typeof mod?.builder === "function" ? mod.builder :
     null);

  if (!factory) {
    throw new Error(
      `Unexpected witness_calculator export. typeof=${typeof mod} keys=${Object.keys(mod || {}).join(",")}`
    );
  }

  const wasmAbs = path.resolve(wasmPath);
  if (!fs.existsSync(wasmAbs)) throw new Error(`.wasm not found: ${wasmAbs}`);
  const wasm = fs.readFileSync(wasmAbs);

  const wc = await factory(wasm);

  const target =
    (wc && typeof wc.calculateWitness === "function") ? wc :
    (wc?.witnessCalculator && typeof wc.witnessCalculator.calculateWitness === "function") ? wc.witnessCalculator :
    null;

  if (!target) throw new Error(`No calculateWitness found. keys(wc)=${Object.keys(wc || {}).join(",")}`);

  return await target.calculateWitness(input, 0);
}

// -------------------------------
// .sym parsing
// circom sym: labelId,witnessIdx,componentId,signalName
// Example: 1,1,106,main.outBytes[0]
// -------------------------------
function parseSym(symPath) {
  const abs = path.resolve(symPath);
  if (!fs.existsSync(abs)) throw new Error(`.sym not found: ${abs}`);

  const txt = fs.readFileSync(abs, "utf8");
  const map = new Map();

  for (const line of txt.split("\n")) {
    const s = line.trim();
    if (!s) continue;
    const parts = s.split(",");
    if (parts.length >= 4) {
      const witnessIdxStr = parts[1].trim();
      const name = parts.slice(3).join(",").trim();
      if (/^\d+$/.test(witnessIdxStr) && name.length > 0) map.set(name, Number(witnessIdxStr));
    }
  }

  if (map.size === 0) throw new Error(`parsed 0 symbols from .sym: ${abs}`);
  return map;
}

// -------------------------------
// Discover artifacts under buildDir
// - *_js/witness_calculator.js
// - *.wasm in same folder
// - *.sym somewhere under buildDir
// -------------------------------
function discoverArtifacts(buildDir) {
  const absBuild = path.resolve(buildDir);
  if (!fs.existsSync(absBuild)) throw new Error(`build dir not found: ${absBuild}`);

  let wcalcPath = null;

  // find witness_calculator.js
  const stack = [absBuild];
  while (stack.length) {
    const d = stack.pop();
    for (const ent of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, ent.name);
      if (ent.isDirectory()) stack.push(p);
      else if (ent.isFile() && ent.name === "witness_calculator.js") wcalcPath = p;
    }
  }
  if (!wcalcPath) throw new Error(`could not find witness_calculator.js under ${absBuild}`);

  // wasm next to it
  const jsDir = path.dirname(wcalcPath);
  const wasmFiles = fs.readdirSync(jsDir).filter((n) => n.endsWith(".wasm"));
  if (wasmFiles.length === 0) throw new Error(`no .wasm next to witness_calculator.js in ${jsDir}`);
  const wasmPath = path.join(jsDir, wasmFiles[0]);

  // find a .sym under buildDir (usually buildDir/*.sym)
  let symPath = null;
  const stack2 = [absBuild];
  while (stack2.length) {
    const d = stack2.pop();
    for (const ent of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, ent.name);
      if (ent.isDirectory()) stack2.push(p);
      else if (ent.isFile() && ent.name.endsWith(".sym")) symPath = p;
    }
  }
  if (!symPath) throw new Error(`could not find any .sym under ${absBuild}`);

  return { wasmPath, wcalcPath, symPath };
}

// -------------------------------
// Helpers: read signals from witness
// -------------------------------
function toBigInt(x) {
  if (typeof x === "bigint") return x;
  // witness can contain strings or numbers
  return BigInt(x.toString());
}

function findKey(sym, exactKey, containsNeedle = null) {
  if (sym.has(exactKey)) return exactKey;
  if (!containsNeedle) return null;
  for (const k of sym.keys()) {
    if (k.includes(containsNeedle)) return k;
  }
  return null;
}

function readOutBytes32(sym, witness, baseName = "outBytes") {
  const out = [];
  for (let i = 0; i < 32; i++) {
    const direct = `main.${baseName}[${i}]`;
    const key = findKey(sym, direct, `${baseName}[${i}]`);
    if (!key) {
      const sample = [...sym.keys()].filter(k => k.includes(baseName)).slice(0, 20);
      throw new Error(`missing sym for ${baseName}[${i}]. sample: ${sample.join(", ")}`);
    }
    const idx = sym.get(key);
    const v = toBigInt(witness[idx]);
    if (v < 0n || v > 255n) throw new Error(`byte out of range at ${i}: ${v}`);
    out.push(Number(v));
  }
  return out;
}

// Convert BigInt -> 32-byte big-endian buffer
function bigIntToBuf32BE(x) {
  let v = x;
  if (v < 0n) throw new Error("negative bigint");
  const buf = Buffer.alloc(32);
  for (let i = 31; i >= 0; i--) {
    buf[i] = Number(v & 0xffn);
    v >>= 8n;
  }
  if (v !== 0n) throw new Error("bigint does not fit in 32 bytes");
  return buf;
}

// Base64 output only (no newline)
function stdoutB64(buf) {
  process.stdout.write(Buffer.from(buf).toString("base64"));
}

// -------------------------------
// Modes
// -------------------------------
async function mode_storageHashBytes32(args) {
  // expects wrapper: main.outBytes[0..31]
  const buildDir = "circuits/build/storagehash";
  const { wasmPath, wcalcPath, symPath } = discoverArtifacts(buildDir);
  const sym = parseSym(symPath);

  const input = { ilo: args.ilo, ihi: args.ihi, op: args.op };
  const witness = await calcWitnessArray(wasmPath, wcalcPath, input);

  const outBytes = readOutBytes32(sym, witness, "outBytes");
  stdoutB64(Buffer.from(outBytes));
}

async function mode_outBytes32(args) {
  // generic: specify buildDir and optionally baseName
  // { "buildDir":"circuits/build/xxx", "baseName":"outBytes", ...inputs }
  const buildDir = args.buildDir;
  if (!buildDir) throw new Error("outBytes32 mode requires args.buildDir");

  const baseName = args.baseName ?? "outBytes";

  // remove meta keys from inputs
  const { buildDir: _bd, baseName: _bn, ...input } = args;

  const { wasmPath, wcalcPath, symPath } = discoverArtifacts(buildDir);
  const sym = parseSym(symPath);

  const witness = await calcWitnessArray(wasmPath, wcalcPath, input);
  const outBytes = readOutBytes32(sym, witness, baseName);

  stdoutB64(Buffer.from(outBytes));
}

async function mode_pubInput0_u256(args) {
  // expects a circuit with a signal named `pubInput0` (either output or public input),
  // we read witness value and return it as base64(32-byte BE).
  //
  // Provide buildDir in args:
  // { "buildDir":"circuits/build/pubinputs", ...circuitInputs }
  const buildDir = args.buildDir;
  if (!buildDir) throw new Error("pubInput0_u256 mode requires args.buildDir");

  const { buildDir: _bd, ...input } = args;

  const { wasmPath, wcalcPath, symPath } = discoverArtifacts(buildDir);
  const sym = parseSym(symPath);

  const witness = await calcWitnessArray(wasmPath, wcalcPath, input);

  // sym key can be "main.pubInput0" or something containing "pubInput0"
  const key = findKey(sym, "main.pubInput0", "pubInput0");
  if (!key) {
    const sample = [...sym.keys()].filter(k => k.includes("pubInput0")).slice(0, 20);
    throw new Error(`missing sym for pubInput0. sample: ${sample.join(", ")}`);
  }

  const idx = sym.get(key);
  const v = toBigInt(witness[idx]);

  const buf = bigIntToBuf32BE(v);
  stdoutB64(buf);
}

// -------------------------------
// Entrypoint
// -------------------------------
async function main() {
  const mode = process.argv[2];
  const jsonStr = process.argv[3];

  if (!mode || !jsonStr) {
    throw new Error(
      "usage: node circuits/scripts/circuit-eval.mjs <mode> <json>\n" +
      "modes: storageHashBytes32 | outBytes32 | pubInput0_u256"
    );
  }

  const args = JSON.parse(jsonStr);

  switch (mode) {
    case "storageHashBytes32":
      return await mode_storageHashBytes32(args);
    case "outBytes32":
      return await mode_outBytes32(args);
    case "pubInput0_u256":
      return await mode_pubInput0_u256(args);
    default:
      throw new Error(`unknown mode: ${mode}`);
  }
}

main().catch((e) => {
  // stderr only
  console.error(e?.stack || e);
  process.exit(1);
});
