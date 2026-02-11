import { execSync } from "node:child_process";
import path from "node:path";
import fs from "node:fs";

const circomFile = process.argv[2] || "circuits/main.circom";
const outDir = "circuits/build";

fs.mkdirSync(outDir, { recursive: true });

console.log(`=== ${circomFile} ===`);


execSync(`circom "${circomFile}" --r1cs -o "${outDir}" -l node_modules -l circuits`, {
  stdio: "inherit",
});


const r1csPath = path.join(outDir, `${path.basename(circomFile, ".circom")}.r1cs`);

execSync(`npx snarkjs r1cs info "${r1csPath}"`, { stdio: "inherit" });

