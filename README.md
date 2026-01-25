# zkgraf-rollup

An zk-rollup for maintaining a trust graph between registered accounts.

This repo contains:
- Solidity contracts (Foundry)
- Circom/snarkjs circuits 
- Specs/docs for encoding, hashing, and threat model

---

## High-level idea

Users enqueue operations (currently `ADD` and `REVOKE`) into an on-chain queue. A batcher (“forger”) selects the next `n` queued ops, constructs `txData`, proves correct state transition in a zkSNARK, and submits a proof to update the on-chain `latestGraphRoot`.

The contract verifies a Groth16 proof against a single public input:
- `pub0 = mask253( sha256(latestRoot, newRoot, batchId, n, storageHash) )`

Where:
- `storageHash = sha256(batchId, start, n, txData)` (packed encoding)
- `txData` is `n * 15` bytes, one fixed-size record per queued op

See [`docs/encoding.md`](docs/encoding.md) for the canonical encoding.

---

## Contracts

### `Rollup.sol`
Core queue + batch submission logic.

Key features:
- **Handshake escrow** for `ADD` edges:
  - `vouch` / `revouch` open a time window after both stakes are funded
  - after the window ends, `finalize` refunds stakes and enqueues an `ADD`
  - during the open window, either party can `steal` (punitive) or `closeWithoutSteal` (refund)
- **Unforged queue**: `unforged[txId]` stores packed records; batches are committed via `txData` and `storageHash`
- **Batch submission**: `submitBatch(newGraphRoot, n, a, b, c)` verifies Groth16 proof and advances `batchId`
- **Fees**:
  - `finalize` and `revoke` require `msg.value == TX_FEE`
  - fees accumulate in `feePool`
  - successful batcher receives `n * TX_FEE` credited to `balances[msg.sender]`

### `Registry.sol`
Simple address → `uint32` index registry.
- `ensureMyIdx()` assigns an id on first call
- `accountIdx(address)` returns 0 if unregistered

### Groth16 Verifier
The Groth16 verifier contract is generated (snarkjs) and typically lives at:
- `src/verifier/Groth16Verifier.sol`

---

## Repository layout
src/ Solidity contracts
src/verifier/ Generated verifier (snarkjs)
test/ Forge unit/invariant tests
script/ Deployment scripts (forge script)
circuits/ Circom circuits + snarkjs artifacts (WIP)
docs/ Specs (encoding, protocol, threat model)
tools/ Helper scripts (hashing/encoding checks)
.github/workflows/ CI

---

## Build & test (Foundry)

### Install Foundry
See https://book.getfoundry.sh/getting-started/installation

### Commands
```bash
forge build
forge test -vvv
forge fmt
```

---

## Contributing
Questions or ideas? Please start with **GitHub Discussions** (Q&A / Ideas). For bugs or clearly scoped work items, open an **Issue**.
