import { expect } from "chai";
import path from "path";
import { wasm as wasm_tester } from "circom_tester";
import { fileURLToPath } from "url";
import crypto from "crypto";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BI = (x) => (typeof x === "bigint" ? x : BigInt(x));

// BN254 prime
const BN254_P =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

function modP(x) {
  let r = x % BN254_P;
  if (r < 0n) r += BN254_P;
  return r;
}

function fieldToBytes32BE(x) {
  // match FieldToBytes(): serialize field element (mod p) as 32-byte big-endian integer
  let v = modP(x);
  const out = Buffer.alloc(32);
  for (let i = 31; i >= 0; i--) {
    out[i] = Number(v & 0xffn);
    v >>= 8n;
  }
  return out;
}

function u32be(n) {
  const b = Buffer.alloc(4);
  b.writeUInt32BE(Number(n >>> 0), 0);
  return b;
}

function u64be(nBig) {
  let x = BigInt(nBig);
  const b = Buffer.alloc(8);
  for (let i = 7; i >= 0; i--) {
    b[i] = Number(x & 0xffn);
    x >>= 8n;
  }
  return b;
}

function sha256(buf) {
  return crypto.createHash("sha256").update(buf).digest();
}

// For StorageHash input: circuit expects digest bits MSB-first per byte.
function digestBytesToBitsMSB(digest32) {
  const bits = new Array(256);
  for (let i = 0; i < 32; i++) {
    const v = digest32[i];
    for (let k = 0; k < 8; k++) {
      bits[i * 8 + k] = BigInt((v >> (7 - k)) & 1);
    }
  }
  return bits;
}

function mask253FromDigestBytes(digest32) {
  const x = BigInt("0x" + digest32.toString("hex"));
  const mask = (1n << 253n) - 1n;
  return x & mask;
}

describe("ProcessBatchTest out[1]=pubInput0", function () {
  this.timeout(240000);

  // MUST match component main = ProcessBatchTest(BATCH_SIZE, SMT_LEVELS)
  const BATCH_SIZE = 3;
  const SMT_LEVELS = 32;

  const circuitPath = path.join(__dirname, "../test_circuits/process_batch_test.circom");
  let circuit;

  before(async () => {
    const repoRoot = path.join(__dirname, "../..");
    circuit = await wasm_tester(circuitPath, {
      include: [path.join(repoRoot, "node_modules"), path.join(repoRoot, "circuits")],
    });
  });

  async function calc(input) {
    const w = await circuit.calculateWitness(input, true);
    await circuit.checkConstraints(w);
    return w;
  }

  async function readOut0(w) {
    if (typeof circuit.getOutput === "function") {
      for (const name of ["out", "main.out"]) {
        try {
          const v = await circuit.getOutput(w, name);
          if (Array.isArray(v) && v.length === 1) return BI(v[0]);
        } catch {}
      }
    }
    throw new Error("Could not read out[0].");
  }

  function zeros2D(rows, cols) {
    return Array.from({ length: rows }, () => Array.from({ length: cols }, () => 0n));
  }

  it("NOP batch (all ops=0) => pubInput0 matches JS transcript; newRoot==oldRoot", async () => {
    const oldRootF = 123n;
    const newRootF = 123n;

    const batchId = 7n;
    const start = 100;
    const numOps = 3; // <= BATCH_SIZE, but ops are all zeros anyway

    // tx data for StorageHash: BATCH_SIZE*9 bytes, all zeros
    const txDataFixed = Buffer.alloc(BATCH_SIZE * 9, 0);
    const storageHash = sha256(txDataFixed);

    const oldRootBytes = fieldToBytes32BE(oldRootF);
    const newRootBytes = fieldToBytes32BE(newRootF);

    const preimage = Buffer.concat([
      oldRootBytes,
      newRootBytes,
      u64be(batchId),
      u32be(start),
      u32be(numOps),
      storageHash,
    ]);

    const pubDigest = sha256(preimage);
    const expected = mask253FromDigestBytes(pubDigest);

    // Build circuit input (all zeros witnesses for NOP)
    const input = {
      oldRootF: oldRootF.toString(),
      newRootF: newRootF.toString(),

      batchId: batchId.toString(),
      start: BigInt(start).toString(),
      numOps: BigInt(numOps).toString(),

      ops: Array.from({ length: BATCH_SIZE }, () => 0n),
      ilos: Array.from({ length: BATCH_SIZE }, () => 0n),
      ihis: Array.from({ length: BATCH_SIZE }, () => 0n),

      neighbors_lo: zeros2D(BATCH_SIZE, 64),
      neighbors_hi: zeros2D(BATCH_SIZE, 64),
      
      oldDeg_lo: Array.from({ length: BATCH_SIZE }, () => 0n),
      oldDeg_hi: Array.from({ length: BATCH_SIZE }, () => 0n),

      siblings_lo: zeros2D(BATCH_SIZE, SMT_LEVELS),
      siblings_hi: zeros2D(BATCH_SIZE, SMT_LEVELS),

      isOld0_lo: Array.from({ length: BATCH_SIZE }, () => 0n),
      isOld0_hi: Array.from({ length: BATCH_SIZE }, () => 0n),

      oldKey_lo: Array.from({ length: BATCH_SIZE }, () => 0n),
      oldKey_hi: Array.from({ length: BATCH_SIZE }, () => 0n),

      oldValue_lo: Array.from({ length: BATCH_SIZE }, () => 0n),
      oldValue_hi: Array.from({ length: BATCH_SIZE }, () => 0n),

      arrIdx_lo: Array.from({ length: BATCH_SIZE }, () => 0n),
      arrIdx_hi: Array.from({ length: BATCH_SIZE }, () => 0n),
    };

    const w = await calc(input);

    if (typeof circuit.assertOut === "function") {
      await circuit.assertOut(w, { out: [expected] });
    } else {
      const out0 = await readOut0(w);
      expect(out0).to.equal(expected);
    }
  });
});
