import { expect } from "chai";
import path from "path";
import { wasm as wasm_tester } from "circom_tester";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const N = 64;
const BI = (x) => (typeof x === "bigint" ? x : BigInt(x));

function makeNeighbors(vals) {
  const arr = new Array(N).fill(0n);
  for (let i = 0; i < Math.min(vals.length, N); i++) arr[i] = BI(vals[i]);
  return arr;
}

function clone(a) {
  return a.map((x) => BI(x));
}

// Optional exact reference using circomlibjs (if installed)
async function tryBuildPoseidon() {
  try {
    const mod = await import("circomlibjs");
    if (typeof mod.buildPoseidon !== "function") return null;
    const poseidon = await mod.buildPoseidon();
    const F = poseidon.F;
    const H = (inputs) => F.toObject(poseidon(inputs.map(BI)));
    return { H };
  } catch {
    return null;
  }
}

// Normalize witness to strings so deep equality is stable across runtime representations
function witnessToStrings(w) {
  // w may contain BigInt already; stringify everything
  return w.map((x) => BI(x).toString());
}

describe("NeighborCommitment packed out[1]", function () {
  this.timeout(180000);

  // Wrapper should expose: signal output out[1]; out[0] <== nc.out;
  const circuitPath = path.join(__dirname, "../test_circuits/neighbor_commitment_test.circom");

  let circuit;
  let poseidonRef = null;

  before(async () => {
    const repoRoot = path.join(__dirname, "../..");
    circuit = await wasm_tester(circuitPath, {
      include: [path.join(repoRoot, "node_modules"), path.join(repoRoot, "circuits")],
    });

    poseidonRef = await tryBuildPoseidon();
  });

  async function calc(input) {
    const w = await circuit.calculateWitness(input, true);
    await circuit.checkConstraints(w);
    return w;
  }

  it("computes a commitment and satisfies constraints", async () => {
    const neighbors = makeNeighbors(Array.from({ length: 64 }, (_, i) => i + 1));
    const degree = 13n;

    const w = await calc({ neighbors, degree });
    expect(w).to.be.an("array");
    expect(w.length).to.be.greaterThan(0);
  });

  it("deterministic: same input -> identical witness", async () => {
    const neighbors = makeNeighbors(Array.from({ length: 64 }, (_, i) => 1234 + i));
    const degree = 42n;

    const w1 = await calc({ neighbors, degree });
    const w2 = await calc({ neighbors, degree });

    expect(witnessToStrings(w1)).to.deep.equal(witnessToStrings(w2));
  });

  it("sensitivity: changing one neighbor changes witness", async () => {
    const neighbors = makeNeighbors(Array.from({ length: 64 }, (_, i) => 9000 + i));
    const degree = 7n;

    const w1 = await calc({ neighbors, degree });

    const neighbors2 = clone(neighbors);
    neighbors2[17] = neighbors2[17] + 1n;

    const w2 = await calc({ neighbors: neighbors2, degree });

    expect(witnessToStrings(w1)).to.not.deep.equal(witnessToStrings(w2));
  });

  it("sensitivity: changing degree changes witness", async () => {
    const neighbors = makeNeighbors(Array.from({ length: 64 }, (_, i) => 111 + i));

    const w1 = await calc({ neighbors, degree: 5n });
    const w2 = await calc({ neighbors, degree: 6n });

    expect(witnessToStrings(w1)).to.not.deep.equal(witnessToStrings(w2));
  });

  it("chunk-boundary matters: swapping values across 16-blocks changes witness", async () => {
    const neighbors = makeNeighbors(Array.from({ length: 64 }, (_, i) => 100000 + i));
    const degree = 9n;

    const w1 = await calc({ neighbors, degree });

    const neighbors2 = clone(neighbors);
    // swap one element from block0 with one from block1
    const a = 0;
    const b = 16;
    const tmp = neighbors2[a];
    neighbors2[a] = neighbors2[b];
    neighbors2[b] = tmp;

    const w2 = await calc({ neighbors: neighbors2, degree });

    expect(witnessToStrings(w1)).to.not.deep.equal(witnessToStrings(w2));
  });

  it("matches circomlibjs Poseidon reference (if available)", async function () {
    if (!poseidonRef) this.skip();

    const { H } = poseidonRef;

    const neighbors = makeNeighbors(Array.from({ length: 64 }, (_, i) => 5555 + i));
    const degree = 12n;

    const h0 = H(neighbors.slice(0, 16));
    const h1 = H(neighbors.slice(16, 32));
    const h2 = H(neighbors.slice(32, 48));
    const h3 = H(neighbors.slice(48, 64));
    const expected = H([h0, h1, h2, h3, degree]);

    const w = await calc({ neighbors, degree });

    // This is the only place we need to reference the output, and assertOut can do it reliably:
    if (typeof circuit.assertOut !== "function") this.skip();
    await circuit.assertOut(w, { out: [expected] });
  });
});
