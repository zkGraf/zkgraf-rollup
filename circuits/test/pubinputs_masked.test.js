import { expect } from "chai";
import path from "path";
import { wasm as wasm_tester } from "circom_tester";
import { fileURLToPath } from "url";
import crypto from "crypto";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BI = (x) => (typeof x === "bigint" ? x : BigInt(x));

function u32be(n) {
  const b = Buffer.alloc(4);
  b.writeUInt32BE(Number(n >>> 0), 0);
  return b;
}

function u64be(nBig) {
  // nBig should fit in uint64 for this test
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

// Convert a 32-byte digest to 256 bits in the exact convention your circom expects:
// digest[0] = MSB of byte0, digest[7]=LSB of byte0, digest[8]=MSB of byte1, ...
function digestBytesToBitsMSB(bytes32) {
  const bits = new Array(256);
  for (let i = 0; i < 32; i++) {
    const v = bytes32[i];
    for (let k = 0; k < 8; k++) {
      bits[i * 8 + k] = BigInt((v >> (7 - k)) & 1);
    }
  }
  return bits;
}

// Mask to 253 bits the same way the circuit does:
// circuit takes digest[] bits (MSB-first), then lsb253[i] = digest[255 - i],
// then Bits2Num(253) with LSB-first => integer formed by digest's 253 LSBs.
function mask253FromDigestBytes(digest32) {
  // interpret digest as big-endian integer, then take low 253 bits
  const x = BigInt("0x" + digest32.toString("hex"));
  const mask = (1n << 253n) - 1n;
  return x & mask;
}

describe("PubInputsMaskedTest out[1]=mask253(sha256(packed))", function () {
  this.timeout(240000);

  const circuitPath = path.join(__dirname, "../test_circuits/pubinputs_masked_test.circom");
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

  it("matches JS sha256(abi.encodePacked(...)) masked to 253", async () => {
    // deterministic-ish test vectors
    const oldRoot = crypto.randomBytes(32);
    const newRoot = crypto.randomBytes(32);

    const batchId = 7n;     // uint64
    const start = 12345;    // uint32
    const n = 10;           // uint32

    // pretend txDataFixed is some bytes; storageHash is sha256(txDataFixed)
    const txDataFixed = crypto.randomBytes(32);
    const storageHash = sha256(txDataFixed); // 32 bytes

    // build pubinputs preimage exactly like Solidity abi.encodePacked:
    // bytes32 oldRoot | bytes32 newRoot | uint64 batchId (BE) | uint32 start (BE) | uint32 n (BE) | bytes32 storageHash
    const preimage = Buffer.concat([
      oldRoot,
      newRoot,
      u64be(batchId),
      u32be(start),
      u32be(n),
      storageHash,
    ]);

    const pubDigest = sha256(preimage);
    const expected = mask253FromDigestBytes(pubDigest);

    // circuit storageDigest wants bits of storageHash (MSB-first per byte)
    const storageDigestBits = digestBytesToBitsMSB(storageHash);

    // build circuit input
    const input = {
      oldRoot: Array.from(oldRoot, (x) => BigInt(x)),
      newRoot: Array.from(newRoot, (x) => BigInt(x)),
      batchId: batchId.toString(),
      start: BigInt(start).toString(),
      n: BigInt(n).toString(),
      storageDigest: storageDigestBits,
    };

    const w = await calc(input);

    if (typeof circuit.assertOut === "function") {
      await circuit.assertOut(w, { out: [expected] });
    } else {
      const out0 = await readOut0(w);
      expect(out0).to.equal(expected);
    }
  });

  it("changing one byte of storageHash changes output", async () => {
    const oldRoot = Buffer.alloc(32, 1);
    const newRoot = Buffer.alloc(32, 2);

    const batchId = 1n;
    const start = 2;
    const n = 3;

    const txDataFixed = Buffer.alloc(32, 9);
    const storageHash = sha256(txDataFixed);

    const storageHash2 = Buffer.from(storageHash);
    storageHash2[0] ^= 0x01;

    const pre1 = Buffer.concat([oldRoot, newRoot, u64be(batchId), u32be(start), u32be(n), storageHash]);
    const pre2 = Buffer.concat([oldRoot, newRoot, u64be(batchId), u32be(start), u32be(n), storageHash2]);

    const exp1 = mask253FromDigestBytes(sha256(pre1));
    const exp2 = mask253FromDigestBytes(sha256(pre2));
    expect(exp1).to.not.equal(exp2);

    const input1 = {
      oldRoot: Array.from(oldRoot, (x) => BigInt(x)),
      newRoot: Array.from(newRoot, (x) => BigInt(x)),
      batchId: batchId.toString(),
      start: BigInt(start).toString(),
      n: BigInt(n).toString(),
      storageDigest: digestBytesToBitsMSB(storageHash),
    };
    const input2 = {
      oldRoot: Array.from(oldRoot, (x) => BigInt(x)),
      newRoot: Array.from(newRoot, (x) => BigInt(x)),
      batchId: batchId.toString(),
      start: BigInt(start).toString(),
      n: BigInt(n).toString(),
      storageDigest: digestBytesToBitsMSB(storageHash2),
    };

    const w1 = await calc(input1);
    const w2 = await calc(input2);

    if (typeof circuit.assertOut === "function") {
      await circuit.assertOut(w1, { out: [exp1] });
      await circuit.assertOut(w2, { out: [exp2] });
    } else {
      const o1 = await readOut0(w1);
      const o2 = await readOut0(w2);
      expect(o1).to.equal(exp1);
      expect(o2).to.equal(exp2);
    }
  });
});
