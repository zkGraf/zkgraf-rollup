import { expect } from "chai";
import path from "path";
import { wasm as wasm_tester } from "circom_tester";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BI = (x) => (typeof x === "bigint" ? x : BigInt(x));

// BN254 base field prime
const BN254_P =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

function modP(x) {
  let r = x % BN254_P;
  if (r < 0n) r += BN254_P;
  return r;
}

function toBytes32BE(x) {
  if (x < 0n) throw new Error("negative");
  const out = new Array(32).fill(0n);
  let v = x;
  for (let i = 31; i >= 0; i--) {
    out[i] = v & 0xffn;
    v >>= 8n;
  }
  return out;
}

describe("FieldToBytesTest out[32]=bytes32(big-endian)", function () {
  this.timeout(240000);

  // MUST match your wrapper filename
  const circuitPath = path.join(__dirname, "../test_circuits/field_to_bytes_test.circom");
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

  async function assertOut32(w, expected) {
    if (typeof circuit.assertOut === "function") {
      await circuit.assertOut(w, { out: expected });
      return;
    }
    if (typeof circuit.getOutput === "function") {
      for (const name of ["out", "main.out"]) {
        try {
          const v = await circuit.getOutput(w, name);
          if (Array.isArray(v) && v.length === 32) {
            expect(v.map(BI)).to.deep.equal(expected);
            return;
          }
        } catch {}
      }
    }
    throw new Error('Could not read out[32]. Ensure wrapper exports "signal output out[32]".');
  }

  it("encodes small value (1) as 31 zero bytes then 0x01", async () => {
    const x = 1n;
    const expected = toBytes32BE(modP(x));
    const w = await calc({ in: x.toString() });
    await assertOut32(w, expected);
  });

  it("encodes a large in-field value correctly", async () => {
    const x = BN254_P - 12345n; // still < p
    const expected = toBytes32BE(x);
    const w = await calc({ in: x.toString() });
    await assertOut32(w, expected);
  });

  it("encodes out-of-field input as (x mod p) (field semantics)", async () => {
    const x = (1n << 254n) + 123456789n; // > p, reduced mod p
    const xr = modP(x);
    const expected = toBytes32BE(xr);

    const w = await calc({ in: x.toString() });
    await assertOut32(w, expected);
  });
});
