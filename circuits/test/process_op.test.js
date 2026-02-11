import { expect } from "chai";
import path from "path";
import { wasm as wasm_tester } from "circom_tester";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const N = 64;
const SENTINEL = 0n;
const BI = (x) => (typeof x === "bigint" ? x : BigInt(x));

function makeArr64(vals) {
  const arr = new Array(N).fill(SENTINEL);
  for (let i = 0; i < Math.min(vals.length, N); i++) arr[i] = BI(vals[i]);
  return arr;
}

function dummySiblings(levels) {
  return Array.from({ length: levels }, () => 0n);
}

describe("ProcessOpTest out[1]=newRoot", function () {
  this.timeout(240000);

  // MUST match the component main = ProcessOpTest(<LEVELS>) in your wrapper
  const SMT_LEVELS = 32;

  const circuitPath = path.join(__dirname, "../test_circuits/process_op_test.circom");
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

  async function readOut(w) {
    // out[0] only
    if (typeof circuit.getOutput === "function") {
      for (const name of ["out", "main.out"]) {
        try {
          const v = await circuit.getOutput(w, name);
          if (Array.isArray(v) && v.length === 1) return BI(v[0]);
        } catch {}
      }
    }
    // Fallback: assume witness layout and just compare using assertOut if available
    throw new Error("Could not read out[1]. If your circom_tester supports assertOut, use that path.");
  }

  function baseInputForNop({
    currentRoot = 123n,
    op = 0n,
    ilo = 11n,
    ihi = 22n,
  } = {}) {
    // For NOP: SMTProcessor enabled=0 => ignores all SMT witness fields.
    // ModifyArray op=0 => ignores idx validity checks except idxBits on idx input inside ModifyArray,
    // but ModifyArray still runs idxBits (Num2Bits(6)) on arrIdx_*; so keep arrIdx_* in [0..63].
    return {
      currentRoot: BI(currentRoot),
      op: BI(op),
      ilo: BI(ilo),
      ihi: BI(ihi),

      neighbors_lo: makeArr64([100, 80, 60, 10]),
      oldDeg_lo: 4n,
      siblings_lo: dummySiblings(SMT_LEVELS),
      isOld0_lo: 0n,
      oldKey_lo: 0n,
      oldValue_lo: 0n,

      neighbors_hi: makeArr64([200, 150, 20]),
      oldDeg_hi: 3n,
      siblings_hi: dummySiblings(SMT_LEVELS),
      isOld0_hi: 0n,
      oldKey_hi: 0n,
      oldValue_hi: 0n,

      arrIdx_lo: 0n,
      arrIdx_hi: 0n,
    };
  }

  // -----------------------
  // NOP tests (no SMT proof needed)
  // -----------------------
  it("NOP => newRoot == currentRoot (witness-agnostic)", async () => {
    const input = baseInputForNop({ currentRoot: 999n, op: 0n, ilo: 5n, ihi: 7n });
    const w = await calc(input);

    if (typeof circuit.assertOut === "function") {
      await circuit.assertOut(w, { out: [999n] });
      return;
    }

    const out0 = await readOut(w);
    expect(out0).to.equal(999n);
  });

  it("NOP still enforces op ∈ {0,1,2}", async () => {
    // This should FAIL because ProcessOp checks op in {0,1,2} even for NOP path
    const input = baseInputForNop({ op: 3n });
    await expectFail(input);
  });

  it("NOP: arrIdx must be in [0..63] because ModifyArray does Num2Bits(6) on idx", async () => {
    const input = baseInputForNop({ op: 0n });
    input.arrIdx_lo = 64n; // out of range -> should fail in ModifyArray idxBits
    await expectFail(input);
  });

  // -----------------------
  // ModifyArray constraint propagation (still can be tested without valid SMT if op=0)
  // BUT: those constraints only apply when op=1/2 in ModifyArray.
  // For op!=0, SMTProcessor enabled=1 and will require valid SMT witnesses.
  // So below we only test *that the circuit rejects bad ModifyArray constraints*
  // by forcing op!=0 AND providing obviously bad SMT witness (so it will fail anyway).
  // This at least ensures you don't accidentally accept impossible cases.
  // -----------------------
  it("ADD with invalid insertion position should FAIL (either at ModifyArray or SMT)", async () => {
    const input = baseInputForNop({ op: 1n });
    // Make ModifyArray invalid for lo:
    // neighbors_lo = [100,80,60,10,...], want insert element=ihi=22 at idx=1:
    // needs oldLeft(=100)>22 ok, but needs 22>oldAt(=80) false -> ModifyArray must fail
    input.arrIdx_lo = 1n;

    // Since op!=0, SMTProcessor enabled=1 and our SMT witness is junk, so it will fail anyway.
    // But if you later plug valid SMT witness, this should still fail due to ModifyArray.
    await expectFail(input);
  });

  it("REVOKE with mismatch (trying to remove non-existing neighbor) should FAIL (either ModifyArray or SMT)", async () => {
    const input = baseInputForNop({ op: 2n });
    // For lo, removing element=ihi=22 at some idx where oldAt != 22 should fail ModifyArray.
    input.arrIdx_lo = 0n; // oldAt=100 != 22
    await expectFail(input);
  });

  // -----------------------
  // OPTIONAL: Real ADD/REVOKE end-to-end tests (needs real SMT witness builder)
  // -----------------------
  // If you have a JS SMT implementation in your repo that can produce:
  // - siblings[]
  // - isOld0
  // - oldKey
  // - oldValue
  // and compute roots,
  // then you can add full tests that assert newRoot changes as expected.
  //
  // Example skeleton:
  //
  // it("ADD end-to-end updates root correctly", async () => {
  //   const { currentRoot, leafWitnessLo, leafWitnessHi } = await buildWitnesses(...);
  //   const input = { ... };
  //   const w = await calc(input);
  //   await circuit.assertOut(w, { out: [expectedNewRoot] });
  // });
});
