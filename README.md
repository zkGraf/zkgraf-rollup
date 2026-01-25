# 1. Introduction

*zkGraf - A queryable trust graph for the Ethereum ecosystem*.

Having a sybil-resistant measure of uniqueness would have many applications in the Ethereum ecosystem. Relying on pure coin voting has vulnerabilities - see here.

One approach to the sybil-resistance problem is using a web-of-trust. ZkGraf is a protocol for building this trust graph on Ethereum. Users can then use this trust graph to prove claims about their uniqueness.

Two key observations:

- To use this trust graph for sybil-resistance checks, it is important that the attestations in the graph carry some “weight”. In other words, we need to ensure links in the graph represent actual trust.
- For robust sybil-resistance, the claims need to be more than just a statement about the attestations of a particular user. They need to be non-local statements, involving a larger portion of the graph. This quickly becomes too expensive to do using on-chain attestations, so instead we need to represent the graph by a state root stored on-chain. Then users can prove claims against this state root using zk proofs. Hence zkGraf is built as an application specific rollup.

Design choices:

- Fully censorship-resistant and trustless. (Ethereum L1 level censorship-resistance).
- Operates like a zk-rollup, but with all DA onchain. (This is fine since the throughput of the rollup is small).
- Batch forging is permissionless. (and cheap, so a user can easily forge their own tx if it is being purposely ignored).
- Use ETH as fee token. (If we use a native fee token then the rollup can be halted by controlling the supply).

# 2. Main Protocol

**Graph Tree:**

A Merkle tree holding the data of the trust graph. Each leaf corresponds to a node in the trust graph, and contains the ash of its trust link data. The Graph Root is stored in the contract.

**Forming a trust link:**

Two addresses perform a ‘trust link handshake’ in the contract. After this handshake is completed successfully, the new link can be added to pending txs queue (when a user adds a new tx to the queue they include a small tip in ETH for the batcher).

**Updating the Graph Root:**

A batcher can take some txs in the queue, apply them to the Graph Tree, work out the new Graph Root, and submit the batch with a zk-proof of correctness. If correct, the contract updates the Graph Root and pays the tx tips to the batcher.

# 3. Privacy

This section looks at the how the protocol can be done in a privacy preserving way. 

The vouching protocol can be done in a privacy-preserving way (analogous to zcash) and claims about a users attestation set can be done too. However proving claims about structural properties of a larger portion of the graph becomes tricky and requires MPC techniques.