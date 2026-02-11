import { expect } from "chai";
import path from "path";
import crypto from "crypto";
import { wasm as wasm_tester } from "circom_tester";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const BI = (x) => (typeof x === "bigint" ? x : BigInt(x));

// MUST match: component main = StorageHashTest(10);
const BATCH_SIZE = 10;

function u32ToBEBytes(x) {
  const v = Number(x);
  if (!Number.isInteger(v) || v < 0 || v > 0xffffffff) throw new Error("u32 out of range");
  return [(v >>> 24) & 0xff, (v >>> 16) & 0xff, (v >>> 8) & 0xff, v & 0xff];
}

function buildTxDataFixedBytes({ ilo, ihi, op }) {
  // txDataFixed length = BATCH_SIZE * 9
  const out = new Uint8Array(BATCH_SIZE * 9);
  for (let i = 0; i < BATCH_SIZE; i++) {
    const base = i * 9;

    const iloBytes = u32ToBEBytes(ilo[i]);
    const ihiBytes = u32ToBEBytes(ihi[i]);

    out[base + 0] = iloBytes[0];
    out[base + 1] = iloBytes[1];
    out[base + 2] = iloBytes[2];
    out[base + 3] = iloBytes[3];

    out[base + 4] = ihiBytes[0];
    out[base + 5] = ihiBytes[1];
    out[base + 6] = ihiBytes[2];
    out[base + 7] = ihiBytes[3];

    const opv = Number(op[i]);
    if (!Number.isInteger(opv) || opv < 0 || opv > 255) throw new Error("op out of byte range");
    out[base + 8] = opv;
  }
  return out;
}

function sha256Bytes(u8) {
  return crypto.createHash("sha256").update(Buffer.from(u8)).digest(); // Buffer length 32
}

// digest bytes -> bit array MSB-first per byte (b7..b0), length 256
function digestBytesToBitsMSB(digestBuf32) {
  const bits = new Array(256);
  let p = 0;
  for (let i = 0; i < 32; i++) {
    const b = digestBuf32[i];
    for (let k = 7; k >= 0; k--) {
      bits[p++] = BigInt((b >> k) & 1);
    }
  }
  return bits;
}

describe("StorageHashTest out[256]=sha256(txDataFixed)", function () {
  this.timeout(240000);

  const circuitPath = path.join(__dirname, "../test_circuits/storage_hash_test.circom");
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

  async function expectFail(input) {
    let failed = false;
    try {
      const w = await circuit.calculateWitness(input, true);
      await circuit.checkConstraints(w);
    } catch {
      failed = true;
    }
    expect(failed).to.equal(true, "Expected constraints to fail, but they passed");
  }

  async function getOutBits(w) {
    if (typeof circuit.getOutput === "function") {
      for (const name of ["out", "main.out"]) {
        try {
          const v = await circuit.getOutput(w, name);
          if (Array.isArray(v) && v.length === 256) return v.map(BI);
        } catch {}
      }
    }
    throw new Error("Could not read out[256].");
  }

  it("hash matches Solidity sha256(txDataFixed) for a sparse batch (tail zeros)", async () => {
    // Full fixed-size arrays; empty slots are zeros (ilo=0, ihi=0, op=0)
    const ilo = new Array(BATCH_SIZE).fill(0);
    const ihi = new Array(BATCH_SIZE).fill(0);
    const op = new Array(BATCH_SIZE).fill(0);

    // Put some ops in the first few slots
    ilo[0] = 11;
    ihi[0] = 22;
    op[0] = 1;

    ilo[1] = 0x01020304;
    ihi[1] = 0xa0b0c0d0;
    op[1] = 2;

    ilo[2] = 0xffffffff;
    ihi[2] = 7;
    op[2] = 1;

    // Expected digest bits from JS sha256(bytes)
    const txBytes = buildTxDataFixedBytes({ ilo, ihi, op });
    const expectedBits = digestBytesToBitsMSB(sha256Bytes(txBytes));

    const input = {
      ilo: ilo.map(BI),
      ihi: ihi.map(BI),
      op: op.map(BI),
    };

    const w = await calc(input);

    if (typeof circuit.assertOut === "function") {
      await circuit.assertOut(w, { out: expectedBits });
    } else {
      const outBits = await getOutBits(w);
      expect(outBits).to.deep.equal(expectedBits);
    }
  });

  it("changing one op byte changes the digest", async () => {
    const ilo = new Array(BATCH_SIZE).fill(0);
    const ihi = new Array(BATCH_SIZE).fill(0);
    const op = new Array(BATCH_SIZE).fill(0);

    ilo[0] = 11;
    ihi[0] = 22;
    op[0] = 1;

    const expected1 = digestBytesToBitsMSB(sha256Bytes(buildTxDataFixedBytes({ ilo, ihi, op })));

    op[0] = 2;

    const expected2 = digestBytesToBitsMSB(sha256Bytes(buildTxDataFixedBytes({ ilo, ihi, op })));

    expect(expected1).to.not.deep.equal(expected2);

    const input = {
      ilo: ilo.map(BI),
      ihi: ihi.map(BI),
      op: op.map(BI),
    };

    const w = await calc(input);

    if (typeof circuit.assertOut === "function") {
      await circuit.assertOut(w, { out: expected2 });
    } else {
      const outBits = await getOutBits(w);
      expect(outBits).to.deep.equal(expected2);
    }
  });

  it("fails if an op value is not a byte (Num2Bits(8) range check)", async () => {
    const ilo = new Array(BATCH_SIZE).fill(0n);
    const ihi = new Array(BATCH_SIZE).fill(0n);
    const op = new Array(BATCH_SIZE).fill(0n);

    op[0] = 256n; // out of range

    await expectFail({ ilo, ihi, op });
  });

  it("fails if ilo is not a uint32 (Num2Bits(32) range check)", async () => {
    const ilo = new Array(BATCH_SIZE).fill(0n);
    const ihi = new Array(BATCH_SIZE).fill(0n);
    const op = new Array(BATCH_SIZE).fill(0n);

    ilo[0] = 1n << 40n;

    await expectFail({ ilo, ihi, op });
  });

  it("fails if ihi is not a uint32 (Num2Bits(32) range check)", async () => {
    const ilo = new Array(BATCH_SIZE).fill(0n);
    const ihi = new Array(BATCH_SIZE).fill(0n);
    const op = new Array(BATCH_SIZE).fill(0n);

    ihi[0] = 1n << 60n;

    await expectFail({ ilo, ihi, op });
  });
});
