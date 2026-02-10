pragma circom 2.1.0;

include "node_modules/circomlib/circuits/smt/smtprocessor.circom";
include "node_modules/circomlib/circuits/poseidon.circom";
include "node_modules/circomlib/circuits/comparators.circom";
include "node_modules/circomlib/circuits/bitify.circom";

//=============================================================================
// CONSTANTS / CONVENTION
//=============================================================================
// Neighbor array: 64 slots, STRICTLY DESCENDING for non-zero values,
// padded with trailing zeros. Sentinel = 0.
// Ops: 0 = NOP, 1 = ADD (insert), 2 = REVOKE (remove)
// SMT leaf value: Poseidon(2)(degree, nbrHash)

//=============================================================================
// NEIGHBOR COMMITMENT
// 4 x Poseidon16 + Poseidon4
//=============================================================================
template NeighborCommitment() {
    signal input neighbors[64];
    signal output out;

    component h0 = Poseidon(16);
    component h1 = Poseidon(16);
    component h2 = Poseidon(16);
    component h3 = Poseidon(16);

    for (var i = 0; i < 16; i++) {
        h0.inputs[i] <== neighbors[i];
        h1.inputs[i] <== neighbors[16 + i];
        h2.inputs[i] <== neighbors[32 + i];
        h3.inputs[i] <== neighbors[48 + i];
    }

    component combine = Poseidon(4);
    combine.inputs[0] <== h0.out;
    combine.inputs[1] <== h1.out;
    combine.inputs[2] <== h2.out;
    combine.inputs[3] <== h3.out;

    out <== combine.out;
}

//=============================================================================
// SORTED ARRAY MODIFY (DESC, sentinel=0) + HASH
// - Idempotent insert/remove using prover hint idx
// - Valid "real insert" requires: old[idx-1] > element > old[idx] (idx==0 allowed)
//   and oldArr[63] == 0 and element != 0
// - Real remove requires: old[idx] == element
// - Remove-missing is idempotent NOP; we also bind idx to insertion position (posOk)
//=============================================================================
template SortedArrayModifyAndHash_Desc0() {
    signal input oldArr[64];
    signal input element;
    signal input idx;         // prover hint in [0..63]
    signal input optype;      // 0=NOP, 1=ADD(insert), 2=REVOKE(remove)

    signal output oldCommitment;
    signal output newCommitment;
    signal output success;    // request is satisfiable under rules
    signal output didInsert;  // real insert happened
    signal output didRemove;  // real remove happened
    signal output newArr[64]; // exposed so caller can hash/inspect if desired

    var SENTINEL = 0;

    // ---- constrain optype in {0,1,2}
    component is0 = IsEqual();
    is0.in[0] <== optype; is0.in[1] <== 0;
    component is1 = IsEqual();
    is1.in[0] <== optype; is1.in[1] <== 1;
    component is2 = IsEqual();
    is2.in[0] <== optype; is2.in[1] <== 2;
    (is0.out + is1.out + is2.out) === 1;

    signal isInsertReq <== is1.out;
    signal isRemoveReq <== is2.out;
    signal isNopReq    <== is0.out;

    // ---- idx range [0..63]
    component idxBits = Num2Bits(6);
    idxBits.in <== idx;

    component idxIsZero = IsZero();
    idxIsZero.in <== idx;

    // ---- mux oldAt = oldArr[idx]
    component eqIdx[64];
    signal oldAt;
    oldAt <== 0;
    for (var j = 0; j < 64; j++) {
        eqIdx[j] = IsEqual();
        eqIdx[j].in[0] <== idx;
        eqIdx[j].in[1] <== j;
        oldAt <== oldAt + eqIdx[j].out * oldArr[j];
    }

    // ---- mux oldLeft = oldArr[idx-1] (0 if idx==0; we gate with idxIsZero)
    component eqLeft[63];
    signal oldLeft;
    oldLeft <== 0;
    for (var k = 0; k < 63; k++) {
        eqLeft[k] = IsEqual();
        eqLeft[k].in[0] <== idx;
        eqLeft[k].in[1] <== (k + 1);
        oldLeft <== oldLeft + eqLeft[k].out * oldArr[k];
    }

    // ---- eqAt = (oldAt == element)
    component atEq = IsEqual();
    atEq.in[0] <== oldAt;
    atEq.in[1] <== element;
    signal eqAt <== atEq.out;

    // ---- notFull = (oldArr[63] == 0)
    component lastIsZero = IsEqual();
    lastIsZero.in[0] <== oldArr[63];
    lastIsZero.in[1] <== SENTINEL;
    signal notFull <== lastIsZero.out;

    // ---- element != 0 for real insert
    component elemIsZero = IsEqual();
    elemIsZero.in[0] <== element;
    elemIsZero.in[1] <== 0;
    signal elemNonZero <== 1 - elemIsZero.out;

    // ---- insertion position validity for DESC order when element absent:
    // require oldLeft > element > oldAt
    // leftGT: element < oldLeft
    // rightGT: oldAt < element
    component leftGT = LessThan(32);
    leftGT.in[0] <== element;
    leftGT.in[1] <== oldLeft;

    component rightGT = LessThan(32);
    rightGT.in[0] <== oldAt;
    rightGT.in[1] <== element;

    // if idx==0, left constraint is vacuously true
    signal leftOk <== idxIsZero.out + (1 - idxIsZero.out) * leftGT.out;
    signal posOk  <== leftOk * rightGT.out;

    // ---- Effective action (idempotent)
    // INSERT: if eqAt => nop, else real insert (must satisfy constraints)
    didInsert <== isInsertReq * (1 - eqAt);
    // REMOVE: only real remove when eqAt
    didRemove <== isRemoveReq * eqAt;
    signal doNop <== 1 - didInsert - didRemove;

    // one-hot sanity
    didInsert * (didInsert - 1) === 0;
    didRemove * (didRemove - 1) === 0;
    doNop     * (doNop     - 1) === 0;
    didInsert + didRemove + doNop === 1;

    // ---- Enforce validity for real insert
    didInsert * (posOk - 1) === 0;
    didInsert * (notFull - 1) === 0;
    didInsert * (elemNonZero - 1) === 0;

    // ---- Bind idx for idempotent remove (remove-missing) as insertion position
    (isRemoveReq * (1 - eqAt)) * (posOk - 1) === 0;

    // ---- success semantics
    // NOP always succeeds
    // REMOVE always succeeds (idempotent allowed)
    // INSERT succeeds if idempotent OR there is room (real insert validity enforced above when didInsert=1)
    success <== isNopReq + isRemoveReq + isInsertReq * (eqAt + (1 - eqAt) * notFull) * elemNonZero;

    // ---- Build newArr with constant indexing (DESC shift rules identical structurally)
    component isBefore[64];
    component isAt[64];

    for (var i = 0; i < 64; i++) {
        isBefore[i] = LessThan(6);
        isBefore[i].in[0] <== i;
        isBefore[i].in[1] <== idx;

        isAt[i] = IsEqual();
        isAt[i].in[0] <== i;
        isAt[i].in[1] <== idx;

        signal before <== isBefore[i].out; // i < idx
        signal at     <== isAt[i].out;     // i == idx
        signal after  <== 1 - before - at; // i > idx

        // INSERT: before keep, at=element, after=old[i-1]
        signal insertVal <== before * oldArr[i]
                          + at     * element
                          + after  * oldArr[i - 1]; // after=0 when i=0

        // REMOVE: before keep, else shift from i+1; last becomes 0
        signal isLast <== (i == 63) ? 1 : 0;
        signal removeVal <== before * oldArr[i]
                          + (1 - before) * (1 - isLast) * oldArr[i + 1]
                          + (1 - before) * isLast * SENTINEL;

        signal expected <== didInsert * insertVal
                         + didRemove * removeVal
                         + doNop     * oldArr[i];

        newArr[i] <== expected;
    }

    // ---- Hash old and new arrays
    component oldHash = NeighborCommitment();
    component newHash = NeighborCommitment();
    for (var t = 0; t < 64; t++) {
        oldHash.neighbors[t] <== oldArr[t];
        newHash.neighbors[t] <== newArr[t];
    }
    oldCommitment <== oldHash.out;
    newCommitment <== newHash.out;
}

//=============================================================================
// EDGE OPERATION STATE MACHINE (SMT fnc bits still needed)
// SMT fnc bits: [1,0]=INSERT, [0,1]=UPDATE, [0,0]=NOP
//=============================================================================
template EdgeOpStates() {
    signal input op;              // 0=NOP, 1=ADD, 2=REVOKE
    signal input isOld0_lo;
    signal input isOld0_hi;

    signal output smtFnc_lo[2];
    signal output smtFnc_hi[2];
    signal output enabled;

    component isAdd = IsEqual();
    isAdd.in[0] <== op;
    isAdd.in[1] <== 1;

    component isRevoke = IsEqual();
    isRevoke.in[0] <== op;
    isRevoke.in[1] <== 2;

    // account_lo
    smtFnc_lo[0] <== isAdd.out * isOld0_lo;                  // insert
    smtFnc_lo[1] <== isAdd.out * (1 - isOld0_lo) + isRevoke.out; // update

    // account_hi
    smtFnc_hi[0] <== isAdd.out * isOld0_hi;
    smtFnc_hi[1] <== isAdd.out * (1 - isOld0_hi) + isRevoke.out;

    enabled <== isAdd.out + isRevoke.out;
}

//=============================================================================
// PROCESS SINGLE EDGE OPERATION
// - Each account leaf value = Poseidon(2)(degree, nbrHash)
//=============================================================================
template ProcessEdgeOp(smtLevels) {
    signal input currentRoot;
    signal output newRoot;

    signal input op;      // 0,1,2
    signal input ilo;
    signal input ihi;

    // Account ilo witness
    signal input neighbors_lo[64];
    signal input siblings_lo[smtLevels];
    signal input isOld0_lo;
    signal input oldKey_lo;
    signal input oldValue_lo;     // SMT leaf value (hash(deg,nbrhash)) for existing
    signal input oldDegree_lo;    // NEW: degree witness for existing

    // Account ihi witness
    signal input neighbors_hi[64];
    signal input siblings_hi[smtLevels];
    signal input isOld0_hi;
    signal input oldKey_hi;
    signal input oldValue_hi;
    signal input oldDegree_hi;    // NEW

    // Index hints
    signal input arrIdx_lo;
    signal input arrIdx_hi;

    // Compute SMT op states
    component states = EdgeOpStates();
    states.op <== op;
    states.isOld0_lo <== isOld0_lo;
    states.isOld0_hi <== isOld0_hi;

    // Enforce oldDegree == 0 when isOld0 == 1 (new account)
    isOld0_lo * oldDegree_lo === 0;
    isOld0_hi * oldDegree_hi === 0;

    // Process neighbor arrays (array path uses optype directly)
    component arrProc_lo = SortedArrayModifyAndHash_Desc0();
    for (var i = 0; i < 64; i++) arrProc_lo.oldArr[i] <== neighbors_lo[i];
    arrProc_lo.element <== ihi;
    arrProc_lo.idx <== arrIdx_lo;
    arrProc_lo.optype <== op;

    component arrProc_hi = SortedArrayModifyAndHash_Desc0();
    for (var j = 0; j < 64; j++) arrProc_hi.oldArr[j] <== neighbors_hi[j];
    arrProc_hi.element <== ilo;
    arrProc_hi.idx <== arrIdx_hi;
    arrProc_hi.optype <== op;

    // Verify array operations succeeded when enabled
    signal arrOk <== (1 - states.enabled) + states.enabled * arrProc_lo.success * arrProc_hi.success;
    arrOk === 1;

    // Compute old leaf hashes and check against SMT oldValue when account exists
    component oldLeaf_lo = Poseidon(2);
    oldLeaf_lo.inputs[0] <== oldDegree_lo;
    oldLeaf_lo.inputs[1] <== arrProc_lo.oldCommitment;

    component oldLeaf_hi = Poseidon(2);
    oldLeaf_hi.inputs[0] <== oldDegree_hi;
    oldLeaf_hi.inputs[1] <== arrProc_hi.oldCommitment;

    // If not new: oldLeaf == oldValue. If new: skip check.
    (1 - isOld0_lo) * (oldLeaf_lo.out - oldValue_lo) === 0;
    (1 - isOld0_hi) * (oldLeaf_hi.out - oldValue_hi) === 0;

    // Update degrees: newDeg = oldDeg + didInsert - didRemove
    signal newDegree_lo <== oldDegree_lo + arrProc_lo.didInsert - arrProc_lo.didRemove;
    signal newDegree_hi <== oldDegree_hi + arrProc_hi.didInsert - arrProc_hi.didRemove;

    // Optionally range-check degrees in [0..64] (7 bits is enough)
    component degBits_lo = Num2Bits(7);
    degBits_lo.in <== newDegree_lo;
    component degBits_hi = Num2Bits(7);
    degBits_hi.in <== newDegree_hi;

    // New leaf values = Poseidon(deg, nbrHash)
    component newLeaf_lo = Poseidon(2);
    newLeaf_lo.inputs[0] <== newDegree_lo;
    newLeaf_lo.inputs[1] <== arrProc_lo.newCommitment;

    component newLeaf_hi = Poseidon(2);
    newLeaf_hi.inputs[0] <== newDegree_hi;
    newLeaf_hi.inputs[1] <== arrProc_hi.newCommitment;

    // SMT Processor for account_lo
    component smt_lo = SMTProcessor(smtLevels);
    smt_lo.oldRoot <== currentRoot;
    for (var a = 0; a < smtLevels; a++) smt_lo.siblings[a] <== siblings_lo[a];
    smt_lo.oldKey <== oldKey_lo;
    smt_lo.oldValue <== oldValue_lo;
    smt_lo.isOld0 <== isOld0_lo;
    smt_lo.newKey <== ilo;
    smt_lo.newValue <== newLeaf_lo.out;
    smt_lo.fnc[0] <== states.smtFnc_lo[0];
    smt_lo.fnc[1] <== states.smtFnc_lo[1];

    // SMT Processor for account_hi (uses intermediate root)
    component smt_hi = SMTProcessor(smtLevels);
    smt_hi.oldRoot <== smt_lo.newRoot;
    for (var b = 0; b < smtLevels; b++) smt_hi.siblings[b] <== siblings_hi[b];
    smt_hi.oldKey <== oldKey_hi;
    smt_hi.oldValue <== oldValue_hi;
    smt_hi.isOld0 <== isOld0_hi;
    smt_hi.newKey <== ihi;
    smt_hi.newValue <== newLeaf_hi.out;
    smt_hi.fnc[0] <== states.smtFnc_hi[0];
    smt_hi.fnc[1] <== states.smtFnc_hi[1];

    newRoot <== smt_hi.newRoot;
}

//=============================================================================
// BATCH PROCESSOR
//=============================================================================
template ProcessBatch(batchSize, smtLevels) {
    signal input pubInputHash;

    signal input oldRoot;
    signal input newRoot;
    signal input batchId;
    signal input numOps;
    signal input storageHash;

    signal input ops[batchSize];
    signal input ilos[batchSize];
    signal input ihis[batchSize];
    signal input stakeIndices[batchSize];
    signal input durationIndices[batchSize];
    signal input timestamps[batchSize];

    signal input neighbors_lo[batchSize][64];
    signal input siblings_lo[batchSize][smtLevels];
    signal input isOld0_lo[batchSize];
    signal input oldKey_lo[batchSize];
    signal input oldValue_lo[batchSize];
    signal input oldDegree_lo[batchSize];     // NEW
    signal input arrIdx_lo[batchSize];

    signal input neighbors_hi[batchSize][64];
    signal input siblings_hi[batchSize][smtLevels];
    signal input isOld0_hi[batchSize];
    signal input oldKey_hi[batchSize];
    signal input oldValue_hi[batchSize];
    signal input oldDegree_hi[batchSize];     // NEW
    signal input arrIdx_hi[batchSize];

    // Bind pubInputHash
    component pubHasher = Poseidon(5);
    pubHasher.inputs[0] <== oldRoot;
    pubHasher.inputs[1] <== newRoot;
    pubHasher.inputs[2] <== batchId;
    pubHasher.inputs[3] <== numOps;
    pubHasher.inputs[4] <== storageHash;
    pubInputHash === pubHasher.out;

    // Verify storageHash
    component txHashers[batchSize];
    signal txHashes[batchSize];

    for (var i = 0; i < batchSize; i++) {
        txHashers[i] = Poseidon(6);
        txHashers[i].inputs[0] <== ops[i];
        txHashers[i].inputs[1] <== ilos[i];
        txHashers[i].inputs[2] <== ihis[i];
        txHashers[i].inputs[3] <== stakeIndices[i];
        txHashers[i].inputs[4] <== durationIndices[i];
        txHashers[i].inputs[5] <== timestamps[i];
        txHashes[i] <== txHashers[i].out;
    }

    component chainHasher[batchSize];
    signal chainedHash[batchSize + 1];
    chainedHash[0] <== 0;

    for (var j = 0; j < batchSize; j++) {
        chainHasher[j] = Poseidon(2);
        chainHasher[j].inputs[0] <== chainedHash[j];
        chainHasher[j].inputs[1] <== txHashes[j];
        chainedHash[j + 1] <== chainHasher[j].out;
    }

    component finalStorageHash = Poseidon(3);
    finalStorageHash.inputs[0] <== batchId;
    finalStorageHash.inputs[1] <== numOps;
    finalStorageHash.inputs[2] <== chainedHash[batchSize];
    storageHash === finalStorageHash.out;

    // Process ops sequentially
    signal roots[batchSize + 1];
    roots[0] <== oldRoot;

    component processors[batchSize];
    component shouldProcess[batchSize];

    for (var t = 0; t < batchSize; t++) {
        shouldProcess[t] = LessThan(8);
        shouldProcess[t].in[0] <== t;
        shouldProcess[t].in[1] <== numOps;

        processors[t] = ProcessEdgeOp(smtLevels);
        processors[t].currentRoot <== roots[t];

        // If beyond numOps => op = 0 (NOP)
        processors[t].op <== shouldProcess[t].out * ops[t];
        processors[t].ilo <== ilos[t];
        processors[t].ihi <== ihis[t];

        for (var a = 0; a < 64; a++) {
            processors[t].neighbors_lo[a] <== neighbors_lo[t][a];
            processors[t].neighbors_hi[a] <== neighbors_hi[t][a];
        }
        for (var b = 0; b < smtLevels; b++) {
            processors[t].siblings_lo[b] <== siblings_lo[t][b];
            processors[t].siblings_hi[b] <== siblings_hi[t][b];
        }

        processors[t].isOld0_lo <== isOld0_lo[t];
        processors[t].oldKey_lo <== oldKey_lo[t];
        processors[t].oldValue_lo <== oldValue_lo[t];
        processors[t].oldDegree_lo <== oldDegree_lo[t];
        processors[t].arrIdx_lo <== arrIdx_lo[t];

        processors[t].isOld0_hi <== isOld0_hi[t];
        processors[t].oldKey_hi <== oldKey_hi[t];
        processors[t].oldValue_hi <== oldValue_hi[t];
        processors[t].oldDegree_hi <== oldDegree_hi[t];
        processors[t].arrIdx_hi <== arrIdx_hi[t];

        roots[t + 1] <== processors[t].newRoot;
    }

    roots[batchSize] === newRoot;
}

//=============================================================================
// MAIN
//=============================================================================
component main {public [pubInputHash]} = ProcessBatch(10, 32);
