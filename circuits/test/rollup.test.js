import { expect } from "chai";
import path from "path";
import { wasm as wasm_tester } from "circom_tester";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

describe("Rollup Circuit", function () {
  this.timeout(120000);

  it("valid transition passes", async () => {
    const circuit = await wasm_tester(path.join(__dirname, "../main.circom"));

    const INPUT = {
      oldRoot: 10,
      newRoot: 133, // 10 + 123
      leaf: 123
    };

    const witness = await circuit.calculateWitness(INPUT, true);
    await circuit.checkConstraints(witness);
  });

  it("invalid transition fails", async () => {
    const circuit = await wasm_tester(path.join(__dirname, "../main.circom"));

    const INPUT = {
      oldRoot: 10,
      newRoot: 999, // wrong
      leaf: 123
    };

    let failed = false;
    try {
      const witness = await circuit.calculateWitness(INPUT, true);
      await circuit.checkConstraints(witness);
    } catch {
      failed = true;
    }

    expect(failed).to.equal(true);
  });
});
