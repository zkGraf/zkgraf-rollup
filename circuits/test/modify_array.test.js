// circuits/test/modify_array.test.js
import { expect } from "chai";
import path from "path";
import { wasm as wasm_tester } from "circom_tester";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const N = 64;
const SENTINEL = 0n;
const BI = (x) => (typeof x === "bigint" ? x : BigInt(x));

function makeOldArr(vals) {
  const arr = new Array(N).fill(SENTINEL);
  for (let i = 0; i < Math.min(vals.length, N); i++) arr[i] = BI(vals[i]);
  return arr;
}

// ---- Reference model that matches *your circuit* semantics:
// - optype in {0,1,2} else constraint fail
// - idx in [0..63] else constraint fail (Num2Bits(6))
// - NOP: unchanged
// - INSERT: MUST satisfy posOk, otherwise constraint fail
// - REMOVE: MUST satisfy oldAt==element, otherwise constraint fail
function modelModify_strict({ oldArr, oldDeg, element, idx, optype }) {
  const arr = oldArr.map(BI);
  const deg = BI(oldDeg);
  const i = Number(BI(idx));
  const elem = BI(element);
  const op = BI(optype);

  if (!(op === 0n || op === 1n || op === 2n)) throw new Error("INVALID_OPTYPE");
  if (!(i >= 0 && i < 64)) throw new Error("IDX_OOR");

  const oldAt = arr[i];
  const oldLeft = i === 0 ? 0n : arr[i - 1];

  const eqAt = oldAt === elem ? 1n : 0n;

  // Circuit: INSERT requires:
  // (idx==0 OR oldLeft > elem) AND (elem > oldAt)
  const leftOk = i === 0 ? 1n : (oldLeft > elem ? 1n : 0n);
  const rightOk = oldAt < elem ? 1n : 0n;
  const posOk = leftOk * rightOk;

  if (op === 1n && posOk !== 1n) throw new Error("INSERT_POS_INVALID");
  if (op === 2n && eqAt !== 1n) throw new Error("REMOVE_MISMATCH");

  const newArr = arr.slice();
  let newDeg = deg;

  if (op === 1n) {
    // insert shift right (drops last)
    for (let k = 63; k > i; k--) newArr[k] = newArr[k - 1];
    newArr[i] = elem;
    newDeg = deg + 1n;
  } else if (op === 2n) {
    // remove shift left (fills last with SENTINEL)
    for (let k = i; k < 63; k++) newArr[k] = newArr[k + 1];
    newArr[63] = SENTINEL;
    newDeg = deg - 1n;
  }

  return { newArr, newDeg };
}

function seededRand(seed) {
  let x = seed >>> 0;
  return () => {
    x ^= x << 13; x >>>= 0;
    x ^= x >>> 17; x >>>= 0;
    x ^= x << 5;  x >>>= 0;
    return x / 0x100000000;
  };
}

function genDescArray(rng, len) {
  const L = Math.max(0, Math.min(64, len));
  if (L === 0) return makeOldArr([]);
  const vals = [];
  let cur = 4_000_000_000;
  for (let i = 0; i < L; i++) {
    const step = 1 + Math.floor(rng() * 1_000_000);
    cur -= step;
    if (cur <= 1) cur = 1;
    vals.push(cur);
  }
  vals.sort((a, b) => b - a);
  return makeOldArr(vals);
}

// Find a valid insertion idx for your local condition; returns null if none.
function findValidInsertIdx(oldArr, element) {
  const e = BI(element);
  for (let i = 0; i < 64; i++) {
    const at = BI(oldArr[i]);
    const left = i === 0 ? null : BI(oldArr[i - 1]);
    const leftOk = i === 0 ? true : (left > e);
    const rightOk = at < e;
    if (leftOk && rightOk) return i;
  }
  return null;
}

describe("ModifyArrayTest packed out[65] (strict constraints)", function () {
  this.timeout(240000);

  const circuitPath = path.join(__dirname, "../test_circuits/modify_array_test.circom");
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

  async function expectOutStrict(input) {
    const norm = {
      oldArr: input.oldArr.map(BI),
      oldDeg: BI(input.oldDeg),
      element: BI(input.element),
      idx: BI(input.idx),
      optype: BI(input.optype),
    };

    const exp = modelModify_strict(norm);
    const expectedOut = [...exp.newArr, exp.newDeg];

    const w = await calc(norm);

    if (typeof circuit.assertOut === "function") {
      await circuit.assertOut(w, { out: expectedOut });
      return;
    }

    if (typeof circuit.getOutput === "function") {
      let out = null;
      for (const name of ["out", "main.out"]) {
        try {
          const v = await circuit.getOutput(w, name);
          if (Array.isArray(v) && v.length === 65) {
            out = v.map(BI);
            break;
          }
        } catch {}
      }
      if (!out) throw new Error("Could not read out[65] via getOutput (tried out, main.out).");
      expect(out).to.deep.equal(expectedOut);
      return;
    }

    throw new Error("Your circom_tester build has neither assertOut nor getOutput.");
  }

  // -----------------------
  // Base tests
  // -----------------------
  it("NOP => unchanged", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    await expectOutStrict({ oldArr, oldDeg: 4n, element: 70n, idx: 2n, optype: 0n });
  });

  it("INSERT valid => shifts right and degree+1", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    // idx=2, left=80, at=60, element=70 => 80>70>60 ok
    await expectOutStrict({ oldArr, oldDeg: 4n, element: 70n, idx: 2n, optype: 1n });
  });

  it("REMOVE valid => shifts left and degree-1", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    await expectOutStrict({ oldArr, oldDeg: 4n, element: 60n, idx: 2n, optype: 2n });
  });

  // -----------------------
  // Constraint failure tests (IMPORTANT for your circuit)
  // -----------------------
  it("INSERT invalid position should FAIL (no degrade-to-NOP)", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    // idx=1, left=100, at=80; element=70 => needs 100>70 and 70>80 (false) => FAIL
    await expectFail({ oldArr, oldDeg: 4n, element: 70n, idx: 1n, optype: 1n });
  });

  it("REMOVE missing should FAIL (no degrade-to-NOP)", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    await expectFail({ oldArr, oldDeg: 4n, element: 70n, idx: 2n, optype: 2n });
  });

  it("Invalid optype (e.g. 3) should FAIL", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    await expectFail({ oldArr, oldDeg: 4n, element: 70n, idx: 2n, optype: 3n });
  });

  it("idx out of range (>=64) should FAIL", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    await expectFail({ oldArr, oldDeg: 4n, element: 70n, idx: 64n, optype: 0n });
  });

  it("INSERT element=0 should FAIL (because element > oldAt can’t hold)", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    await expectFail({ oldArr, oldDeg: 4n, element: 0n, idx: 4n, optype: 1n });
  });

  // -----------------------
  // Boundary tests
  // -----------------------
  it("Boundary: insert at idx=0 when element > head => insert", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    await expectOutStrict({ oldArr, oldDeg: 4n, element: 150n, idx: 0n, optype: 1n });
  });

  it("Boundary: remove at idx=0 when matches => remove", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    await expectOutStrict({ oldArr, oldDeg: 4n, element: 100n, idx: 0n, optype: 2n });
  });

  it("Note: INSERT when full is allowed by this circuit (drops last element)", async () => {
    // Your circuit currently does NOT constrain "not full".
    // This test documents current behavior.
    const full = Array.from({ length: 64 }, (_, i) => BI(10_000 - i)); // all nonzero
    // Pick a valid local slot: idx=0, element bigger than head => valid
    await expectOutStrict({ oldArr: full, oldDeg: 64n, element: 20_000n, idx: 0n, optype: 1n });
  });

  it("REMOVE on a zero slot with element=0 is allowed (documents behavior)", async () => {
    // Because atEq checks oldAt==element, if both are 0 then remove is valid.
    const oldArr = makeOldArr([100, 80, 60, 10]); // zeros after idx=4
    await expectOutStrict({ oldArr, oldDeg: 4n, element: 0n, idx: 10n, optype: 2n });
  });

  // -----------------------
  // Fuzz: generate only VALID cases for INSERT/REMOVE
  // -----------------------
  it("Fuzz (deterministic): valid ops match strict model (100 trials)", async () => {
    const rng = seededRand(123456);
    const TRIALS = 100;

    for (let t = 0; t < TRIALS; t++) {
      const len = Math.floor(rng() * 30);
      const oldArr = genDescArray(rng, len);

      const optype = Math.floor(rng() * 3); // 0/1/2
      const deg = BigInt(len); // not enforced by circuit, but keep sensible
      let element = BI(1 + Math.floor(rng() * 4_000_000_000));
      let idx = BI(Math.floor(rng() * 64));

      if (optype === 1) {
        // Make INSERT valid: choose idx that satisfies posOk, else fallback to NOP.
        const maybe = findValidInsertIdx(oldArr, element);
        if (maybe === null) {
          // no valid spot -> just do NOP case
          await expectOutStrict({ oldArr, oldDeg: deg, element, idx: 0n, optype: 0n });
          continue;
        }
        idx = BI(maybe);
      } else if (optype === 2) {
        // Make REMOVE valid: set element = oldArr[idx]
        idx = BI(Math.floor(rng() * 64));
        element = BI(oldArr[Number(idx)]);
      }

      await expectOutStrict({ oldArr, oldDeg: deg, element, idx, optype: BI(optype) });
    }
  });
});
