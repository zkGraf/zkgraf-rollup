# Encoding and Commitments

This document is the **source of truth** for how the contract encodes batch data and computes the Groth16/circom public input `pub0`.

If any part of this document changes, you must update the circuit/prover accordingly (and likely regenerate the verifier / redeploy).

---

## Definitions

- `txId`: monotonically increasing queue id (`nextTxId`).
- `start`: first tx id included in a batch, `start = lastForgedId + 1`.
- `n`: number of txs included in the batch (`1..MAX_BATCH`).
- `txData`: concatenation of `n` fixed-size records (15 bytes each).
- `storageHash`: SHA-256 commitment to `(batchId, start, n, txData)`.
- `pubInputsHash`: SHA-256 commitment to `(latestRoot, newRoot, batchId, n, storageHash)`.
- `pub0`: masked `pubInputsHash` (low 253 bits), used as the **single public signal**.

**Endianness:** All multi-byte integers inside `txData` are encoded in **big-endian**.

---

## 1) `txData` record format (15 bytes per tx)

Each record corresponds to one queued operation and is encoded as:

| Field            | Type   | Bytes |
|------------------|--------|-------|
| `ilo`            | uint32 | 4     |
| `ihi`            | uint32 | 4     |
| `stakeIndex`     | uint8  | 1     |
| `durationIndex`  | uint8  | 1     |
| `op`             | uint8  | 1     |
| `ts`             | uint32 | 4     |

Total = **15 bytes**.

### Byte layout

For record `i` (0-indexed), offset `off = 15 * i`:

- `txData[off+0..3]`   = `ilo` (uint32 big-endian)
- `txData[off+4..7]`   = `ihi` (uint32 big-endian)
- `txData[off+8]`      = `stakeIndex` (uint8)
- `txData[off+9]`      = `durationIndex` (uint8)
- `txData[off+10]`     = `op` (uint8)
- `txData[off+11..14]` = `ts` (uint32 big-endian)

### Solidity reference (exact)

```solidity
// ilo (big-endian)
txData[off + 0] = bytes1(uint8(ilo >> 24));
txData[off + 1] = bytes1(uint8(ilo >> 16));
txData[off + 2] = bytes1(uint8(ilo >> 8));
txData[off + 3] = bytes1(uint8(ilo));

// ihi (big-endian)
txData[off + 4] = bytes1(uint8(ihi >> 24));
txData[off + 5] = bytes1(uint8(ihi >> 16));
txData[off + 6] = bytes1(uint8(ihi >> 8));
txData[off + 7] = bytes1(uint8(ihi));

// stake/dur/op
txData[off + 8]  = bytes1(stakeIndex);
txData[off + 9]  = bytes1(durationIndex);
txData[off + 10] = bytes1(op);

// ts (big-endian)
txData[off + 11] = bytes1(uint8(ts >> 24));
txData[off + 12] = bytes1(uint8(ts >> 16));
txData[off + 13] = bytes1(uint8(ts >> 8));
txData[off + 14] = bytes1(uint8(ts));
