# Circuits

This folder contains the Circom circuits + tooling used by the Foundry project for end-to-end (integration) tests.

- **Solidity verifier contract** is generated into `src/Verifier.sol` so Foundry compiles it.
- **Integration tests** (Foundry) call the circuit toolchain via **FFI** to generate proofs and verify them on-chain.

---

## Folder structure

Typical layout:

- `circuits/` — `.circom` sources
- `circuits/build/` — compiled artifacts (`.r1cs`, `.sym`, `*_js/`, `.zkey`, tmp proof outputs)
- `circuits/fixtures/` — JSON inputs used by integration tests
- `circuits/powersOfTau/` — prepared Phase2 `.ptau`
- `circuits/scripts/` — helper scripts (prove/pack calldata for Foundry)

> Note: `circuits/build/` is usually **generated**. Decide whether you commit it, cache it in CI, or regenerate locally.

---

## Prerequisites

- `circom` installed (Circom compiler)
- Node.js (for `snarkjs` + witness generation)
- `snarkjs` available (recommended as a dev dependency)

Check `snarkjs` works:
npx snarkjs --version


## Trusted setup inputs (Powers of Tau)
We use a prepared Phase2 ptau file (bn128), e.g.:

circuits/powersOfTau/powersOfTau28_hez_final_20.ptau

This file must be large enough for the circuit’s constraint count (power >= needed constraints).

Build + setup (Groth16) for a circuit
These commands compile the circuit, create a Groth16 zkey, verify it, and export the Solidity verifier.

Assuming:

- circuit: circuits/main.circom

- ptau: circuits/powersOfTau/powersOfTau28_hez_final_20.ptau

- output: circuits/build/main/

- verifier: src/Verifier.sol

Run from repo root:

## 0) Prepare output dirs
mkdir -p circuits/build/main
mkdir -p circuits/build/main/zkey
mkdir -p src

## 1) Compile the circuit (R1CS + WASM/JS + SYM)
`circom circuits/main.circom --r1cs --wasm --sym -o circuits/build/main`

Outputs (typical):

circuits/build/main/main.r1cs

circuits/build/main/main.sym

circuits/build/main/main_js/ (contains main.wasm + witness generator JS)

(Optional: check circuit stats using `npx snarkjs r1cs info circuits/build/main/main.r1cs`)

## 2) Create the zkey (Groth16)

- For this you need to have a ptau file in circuits/powersOfTau/ 
- Can be downloaded from https://github.com/iden3/snarkjs?tab=readme-ov-file#7-prepare-phase-2 

### 2a) Initial setup
npx snarkjs groth16 setup \
  circuits/build/main/main.r1cs \
  circuits/powersOfTau/powersOfTau28_hez_final_20.ptau \
  circuits/build/main/zkey/main_0000.zkey

### 2b) Optional: contribute entropy (local dev)
npx snarkjs zkey contribute \
  circuits/build/main/zkey/main_0000.zkey \
  circuits/build/main/zkey/main_0001.zkey \
  --name="contrib1" -v -e="some entropy"

### 2c) Finalize with a beacon (recommended)
npx snarkjs zkey beacon \
  circuits/build/main/zkey/main_0001.zkey \
  circuits/build/main/zkey/main_final.zkey \
  0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f \
  10 \
  -n="final beacon"

If you skip 2b, run beacon on `main_0000.zkey` instead.

## 3) Verify the zkey
`npx snarkjs zkey verify circuits/build/main/main.r1cs circuits/powersOfTau/powersOfTau28_hez_final_20.ptau circuits/build/main/zkey/main_final.zkey`

## 4) Export verifier artifacts
Solidity verifier (used by Foundry)
`npx snarkjs zkey export solidityverifier circuits/build/main/zkey/main_final.zkey src/Verifier.sol`

Verification key JSON (useful for debugging/tooling)
`npx snarkjs zkey export verificationkey circuits/build/main/zkey/main_final.zkey circuits/build/main/verification_key.json`
