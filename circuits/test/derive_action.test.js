import { expect } from "chai";
import path from "path";
import { wasm as wasm_tester } from "circom_tester";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function makeOldArr(vals) {
  const arr = new Array(64).fill(0);
  for (let i = 0; i < Math.min(vals.length, 64); i++) arr[i] = vals[i];
  return arr;
}

describe("DeriveAction (NoSuccess / always-succeeds)", function () {
  this.timeout(180000);

  const circuitPath = path.join(__dirname, "../test_circuits/derive_action_test.circom");
  let circuit;

  before(async () => {
    const repoRoot = path.join(__dirname, "../..");
    circuit = await wasm_tester(circuitPath, {
      include: [path.join(repoRoot, "node_modules"), path.join(repoRoot, "circuits")]
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

  async function expectOut(input, expectedArray3) {
    const w = await calc(input);

    if (typeof circuit.assertOut === "function") {
      await circuit.assertOut(w, { out: expectedArray3 });
      return;
    }

    if (typeof circuit.getOutput === "function") {
      const out = await circuit.getOutput(w, "main.out");
      const norm = out.map((x) => Number(x));
      expect(norm).to.deep.equal(expectedArray3);
      return;
    }

    throw new Error(
      "Your circom_tester build has neither assertOut nor getOutput; cannot check outputs."
    );
  }

  // -----------------------
  // Base tests
  // -----------------------
  it("NOP request => [1,0,0]", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    await expectOut({ oldArr, element: 70, idx: 2, optype: 0 }, [1, 0, 0]);
  });

  it("INSERT idempotent (element at idx) => [1,0,0]", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    await expectOut({ oldArr, element: 80, idx: 1, optype: 1 }, [1, 0, 0]);
  });

  it("INSERT real valid => [0,1,0]", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    await expectOut({ oldArr, element: 70, idx: 2, optype: 1 }, [0, 1, 0]);
  });

  it("INSERT invalid position => NOP [1,0,0]", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    await expectOut({ oldArr, element: 70, idx: 1, optype: 1 }, [1, 0, 0]);
  });

  it("INSERT when full + element absent => NOP [1,0,0]", async () => {
    const full = Array.from({ length: 64 }, (_, i) => 1000 - i);
    await expectOut({ oldArr: full, element: 500, idx: 10, optype: 1 }, [1, 0, 0]);
  });

  it("INSERT element=0 => NOP [1,0,0]", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    await expectOut({ oldArr, element: 0, idx: 4, optype: 1 }, [1, 0, 0]);
  });

  it("REMOVE real when element present at idx => [0,0,1]", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    await expectOut({ oldArr, element: 60, idx: 2, optype: 2 }, [0, 0, 1]);
  });

  it("REMOVE missing => NOP [1,0,0] (idx irrelevant)", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    await expectOut({ oldArr, element: 70, idx: 50, optype: 2 }, [1, 0, 0]);
  });

  it("Invalid optype (e.g. 3) should FAIL", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    await expectFail({ oldArr, element: 70, idx: 2, optype: 3 });
  });

  it("idx out of range (>=64) should FAIL", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    await expectFail({ oldArr, element: 70, idx: 64, optype: 0 });
  });

  // -----------------------
  // Boundary tests
  // -----------------------
  it("Boundary: insert at idx=0 (element larger than head) => [0,1,0]", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    await expectOut({ oldArr, element: 150, idx: 0, optype: 1 }, [0, 1, 0]);
  });

  it("Boundary: insert near tail (just above 0) => [0,1,0]", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    // should insert right before first 0, which is at idx=4 here
    await expectOut({ oldArr, element: 1, idx: 4, optype: 1 }, [0, 1, 0]);
  });

  it("Boundary: remove at idx=0 when matches => [0,0,1]", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]);
    await expectOut({ oldArr, element: 100, idx: 0, optype: 2 }, [0, 0, 1]);
  });

  it("Boundary: remove missing at idx=63 => NOP [1,0,0] when element!=0", async () => {
    const oldArr = makeOldArr([100, 80, 60, 10]); // oldArr[63]=0
    // remove element 1 at idx=63 (oldAt=0 != 1) => missing => NOP
    await expectOut({ oldArr, element: 1, idx: 63, optype: 2 }, [1, 0, 0]);
  });

  // -----------------------
  // Fuzz (deterministic)
  // -----------------------
  function seededRand(seed) {
    let x = seed >>> 0;
    return () => {
      x ^= x << 13; x >>>= 0;
      x ^= x >> 17; x >>>= 0;
      x ^= x << 5;  x >>>= 0;
      return x / 0x100000000;
    };
  }

  function genDescArray(rng, len) {
    const L = Math.max(1, Math.min(64, len));
    const vals = [];
    let cur = 4000000000;
    for (let i = 0; i < L; i++) {
      const step = 1 + Math.floor(rng() * 1000000);
      cur = cur - step;
      if (cur <= 1) cur = 1;
      vals.push(cur);
    }
    return makeOldArr(vals);
  }

  function findInsertionIdxDesc(oldArr, element) {
    for (let i = 0; i < 64; i++) {
      const at = oldArr[i];
      const left = i === 0 ? null : oldArr[i - 1];
      const leftOk = i === 0 ? true : (left > element);
      const rightOk = element > at;
      if (leftOk && rightOk) return i;
    }
    return 63;
  }

  function isFull(oldArr) {
    return oldArr[63] !== 0;
  }

  it("Fuzz (deterministic): outputs match local model and are one-hot", async () => {
    const rng = seededRand(123456);
    const N = 40;

    for (let t = 0; t < N; t++) {
      const len = 1 + Math.floor(rng() * 64);
      const oldArr = genDescArray(rng, len);

      const optype = Math.floor(rng() * 3);

      let element;
      const pickExisting = rng() < 0.4;
      if (pickExisting) {
        const firstZero = oldArr.findIndex((v) => v === 0);
        const maxIdx = firstZero === -1 ? 63 : Math.max(0, firstZero - 1);
        const pickIdx = Math.floor(rng() * (maxIdx + 1));
        element = oldArr[pickIdx];
      } else {
        element = 1 + Math.floor(rng() * 4000000000);
      }
      if (rng() < 0.1) element = 0;

      let idx;
      if (rng() < 0.5) idx = findInsertionIdxDesc(oldArr, element);
      else idx = Math.floor(rng() * 64);

      // local model
      const oldAt = oldArr[idx];
      const eqAt = oldAt === element ? 1 : 0;
      const notFull = isFull(oldArr) ? 0 : 1;
      const elemNonZero = element === 0 ? 0 : 1;

      const leftOk = idx === 0 ? 1 : (oldArr[idx - 1] > element ? 1 : 0);
      const rightOk = element > oldArr[idx] ? 1 : 0;
      const posOk = leftOk * rightOk;

      let expIns = 0;
      let expRem = 0;
      if (optype === 1) expIns = (1 - eqAt) * notFull * elemNonZero * posOk;
      if (optype === 2) expRem = eqAt;

      const expNop = 1 - expIns - expRem;
      expect(expNop + expIns + expRem).to.equal(1);

      await expectOut({ oldArr, element, idx, optype }, [expNop, expIns, expRem]);
    }
  });
});
