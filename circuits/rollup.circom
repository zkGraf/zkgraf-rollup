pragma circom 2.1.0;

include "node_modules/circomlib/circuits/smt/smtprocessor.circom";
include "node_modules/circomlib/circuits/poseidon.circom";
include "node_modules/circomlib/circuits/comparators.circom";
include "node_modules/circomlib/circuits/mux1.circom";

//=============================================================================
// CONSTANTS
//=============================================================================
// SMT depth: 32 (key = uint32 account_id)
// Neighbor array: 64 slots, sorted ascending, sentinel = 2^32 - 1
// Ops: 0 = NOP, 1 = ADD, 2 = REVOKE

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
// SORTED ARRAY OPERATIONS
// Inline insert/remove with commitment computation
//=============================================================================

template SortedArrayModifyAndHash() {
    signal input oldArr[64];
    signal input element;
    signal input idx;              // Insert or remove index (prover hint)
    signal input fnc[2];           // [0,0]=NOP, [1,0]=INSERT, [0,1]=REMOVE
    
    signal output oldCommitment;
    signal output newCommitment;
    signal output success;         // 1 if operation valid
    
    var SENTINEL = 4294967295;     // 2^32 - 1
    
    // Decode fnc
    signal isInsert <== fnc[0] * (1 - fnc[1]);
    signal isRemove <== (1 - fnc[0]) * fnc[1];
    signal isNop <== (1 - fnc[0]) * (1 - fnc[1]);
    
    // Find count (first sentinel position)
    // Prover provides idx which implicitly encodes count context
    
    // Validate insert: oldArr[idx-1] < element < oldArr[idx]
    // (handles boundaries via sentinel)
    
    component leftBoundOk = LessThan(32);
    component rightBoundOk = LessThan(32);
    
    // Left bound: element > oldArr[idx-1] (or idx=0)
    component idxIsZero = IsZero();
    idxIsZero.in <== idx;
    
    signal leftVal <== (1 - idxIsZero.out) * oldArr[idx - 1 + idxIsZero.out];
    leftBoundOk.in[0] <== leftVal;
    leftBoundOk.in[1] <== element;
    signal leftOk <== idxIsZero.out + (1 - idxIsZero.out) * leftBoundOk.out;
    
    // Right bound: element < oldArr[idx]
    rightBoundOk.in[0] <== element;
    rightBoundOk.in[1] <== oldArr[idx];
    
    // Insert valid: leftOk AND rightOk AND oldArr[63] == SENTINEL (not full)
    component notFull = IsEqual();
    notFull.in[0] <== oldArr[63];
    notFull.in[1] <== SENTINEL;
    
    signal insertValid <== leftOk * rightBoundOk.out * notFull.out;
    
    // Validate remove: oldArr[idx] == element
    component removeMatch = IsEqual();
    removeMatch.in[0] <== oldArr[idx];
    removeMatch.in[1] <== element;
    
    signal removeValid <== removeMatch.out;
    
    // Overall success
    success <== isInsert * insertValid + isRemove * removeValid + isNop;
    
    // Build old and new arrays, compute commitments inline
    component oldHash = NeighborCommitment();
    component newHash = NeighborCommitment();
    
    component isBefore[64];
    component isAt[64];
    
    for (var i = 0; i < 64; i++) {
        isBefore[i] = LessThan(8);
        isBefore[i].in[0] <== i;
        isBefore[i].in[1] <== idx;
        
        isAt[i] = IsEqual();
        isAt[i].in[0] <== i;
        isAt[i].in[1] <== idx;
        
        // Old array: unchanged
        oldHash.neighbors[i] <== oldArr[i];
        
        // New array depends on operation
        // INSERT: shift right after idx, insert element at idx
        // REMOVE: shift left after idx, put SENTINEL at end
        // NOP: unchanged
        
        // Compute shifted indices safely
        signal prevIdx <== i - 1 + isBefore[i].out + isAt[i].out;  // Clamp to 0
        signal nextIdx <== i + 1 - isAt[i].out * (i == 63 ? 1 : 0); // Clamp to 63
        
        // Insert value: before=keep, at=element, after=oldArr[i-1]
        signal insertVal <== isBefore[i].out * oldArr[i]
                           + isAt[i].out * element
                           + (1 - isBefore[i].out - isAt[i].out) * oldArr[prevIdx];
        
        // Remove value: before=keep, at and after=oldArr[i+1], last=SENTINEL
        component isLast = IsEqual();
        isLast.in[0] <== i;
        isLast.in[1] <== 63;
        
        signal removeVal <== isBefore[i].out * oldArr[i]
                           + (1 - isBefore[i].out) * (1 - isLast.out) * oldArr[i + 1 - isLast.out]
                           + isLast.out * SENTINEL;
        
        // Select based on operation
        signal newVal <== isInsert * insertVal
                        + isRemove * removeVal
                        + isNop * oldArr[i];
        
        newHash.neighbors[i] <== newVal;
    }
    
    oldCommitment <== oldHash.out;
    newCommitment <== newHash.out;
}

//=============================================================================
// EDGE OPERATION STATE MACHINE
// Computes fnc bits for SMT and array operations
//=============================================================================

template EdgeOpStates() {
    signal input op;              // 0=NOP, 1=ADD, 2=REVOKE
    signal input isOld0_lo;       // 1 if account_lo is new (not in SMT)
    signal input isOld0_hi;       // 1 if account_hi is new (not in SMT)
    
    // SMT fnc bits: [1,0]=INSERT, [0,1]=UPDATE, [0,0]=NOP
    signal output smtFnc_lo[2];
    signal output smtFnc_hi[2];
    
    // Array fnc bits: [1,0]=INSERT, [0,1]=REMOVE, [0,0]=NOP
    signal output arrFnc[2];
    
    signal output enabled;        // 1 if any change happens
    
    // Decode op
    component isAdd = IsEqual();
    isAdd.in[0] <== op;
    isAdd.in[1] <== 1;
    
    component isRevoke = IsEqual();
    isRevoke.in[0] <== op;
    isRevoke.in[1] <== 2;
    
    // SMT operations for account_lo
    // ADD + new account: INSERT [1,0]
    // ADD + existing: UPDATE [0,1]
    // REVOKE: UPDATE [0,1]
    smtFnc_lo[0] <== isAdd.out * isOld0_lo;
    smtFnc_lo[1] <== isAdd.out * (1 - isOld0_lo) + isRevoke.out;
    
    // SMT operations for account_hi (same logic)
    smtFnc_hi[0] <== isAdd.out * isOld0_hi;
    smtFnc_hi[1] <== isAdd.out * (1 - isOld0_hi) + isRevoke.out;
    
    // Array operations
    // ADD: INSERT [1,0]
    // REVOKE: REMOVE [0,1]
    arrFnc[0] <== isAdd.out;
    arrFnc[1] <== isRevoke.out;
    
    enabled <== isAdd.out + isRevoke.out;
}

//=============================================================================
// PROCESS SINGLE EDGE OPERATION
//=============================================================================

template ProcessEdgeOp(smtLevels) {
    signal input currentRoot;
    signal output newRoot;
    
    // Operation data
    signal input op;              // 0=NOP, 1=ADD, 2=REVOKE
    signal input ilo;             // Lower account ID
    signal input ihi;             // Higher account ID
    
    // Account ilo witness data
    signal input neighbors_lo[64];
    signal input siblings_lo[smtLevels];
    signal input isOld0_lo;
    signal input oldKey_lo;       // Should equal ilo for UPDATE, anything for INSERT
    signal input oldValue_lo;     // Previous nbrhash (0 if new)
    
    // Account ihi witness data
    signal input neighbors_hi[64];
    signal input siblings_hi[smtLevels];
    signal input isOld0_hi;
    signal input oldKey_hi;
    signal input oldValue_hi;
    
    // Index hints for sorted array operations
    signal input arrIdx_lo;       // Where to insert/remove ihi in neighbors_lo
    signal input arrIdx_hi;       // Where to insert/remove ilo in neighbors_hi
    
    // Compute operation states
    component states = EdgeOpStates();
    states.op <== op;
    states.isOld0_lo <== isOld0_lo;
    states.isOld0_hi <== isOld0_hi;
    
    // Process account_lo's neighbor array
    component arrProc_lo = SortedArrayModifyAndHash();
    for (var i = 0; i < 64; i++) {
        arrProc_lo.oldArr[i] <== neighbors_lo[i];
    }
    arrProc_lo.element <== ihi;
    arrProc_lo.idx <== arrIdx_lo;
    arrProc_lo.fnc[0] <== states.arrFnc[0];
    arrProc_lo.fnc[1] <== states.arrFnc[1];
    
    // Process account_hi's neighbor array
    component arrProc_hi = SortedArrayModifyAndHash();
    for (var i = 0; i < 64; i++) {
        arrProc_hi.oldArr[i] <== neighbors_hi[i];
    }
    arrProc_hi.element <== ilo;
    arrProc_hi.idx <== arrIdx_hi;
    arrProc_hi.fnc[0] <== states.arrFnc[0];
    arrProc_hi.fnc[1] <== states.arrFnc[1];
    
    // Verify array operations succeeded (if not NOP)
    signal arrOk <== (1 - states.enabled) + states.enabled * arrProc_lo.success * arrProc_hi.success;
    arrOk === 1;
    
    // Verify old commitments match witness
    signal oldCommitOk_lo <== (isOld0_lo * 1) + (1 - isOld0_lo) * IsEqual()([arrProc_lo.oldCommitment, oldValue_lo]);
    signal oldCommitOk_hi <== (isOld0_hi * 1) + (1 - isOld0_hi) * IsEqual()([arrProc_hi.oldCommitment, oldValue_hi]);
    // Note: If isOld0=1 (new account), we don't check oldValue (it's 0 in SMT)
    
    // SMT Processor for account_lo
    component smt_lo = SMTProcessor(smtLevels);
    smt_lo.oldRoot <== currentRoot;
    for (var i = 0; i < smtLevels; i++) {
        smt_lo.siblings[i] <== siblings_lo[i];
    }
    smt_lo.oldKey <== oldKey_lo;
    smt_lo.oldValue <== oldValue_lo;
    smt_lo.isOld0 <== isOld0_lo;
    smt_lo.newKey <== ilo;
    smt_lo.newValue <== arrProc_lo.newCommitment;
    smt_lo.fnc[0] <== states.smtFnc_lo[0];
    smt_lo.fnc[1] <== states.smtFnc_lo[1];
    
    // SMT Processor for account_hi (uses intermediate root)
    component smt_hi = SMTProcessor(smtLevels);
    smt_hi.oldRoot <== smt_lo.newRoot;
    for (var i = 0; i < smtLevels; i++) {
        smt_hi.siblings[i] <== siblings_hi[i];
    }
    smt_hi.oldKey <== oldKey_hi;
    smt_hi.oldValue <== oldValue_hi;
    smt_hi.isOld0 <== isOld0_hi;
    smt_hi.newKey <== ihi;
    smt_hi.newValue <== arrProc_hi.newCommitment;
    smt_hi.fnc[0] <== states.smtFnc_hi[0];
    smt_hi.fnc[1] <== states.smtFnc_hi[1];
    
    newRoot <== smt_hi.newRoot;
}

//=============================================================================
// BATCH PROCESSOR
//=============================================================================

template ProcessBatch(batchSize, smtLevels) {
    // === Public Input ===
    signal input pubInputHash;
    
    // === Private Inputs (bound via pubInputHash) ===
    signal input oldRoot;
    signal input newRoot;
    signal input batchId;
    signal input numOps;
    signal input storageHash;
    
    // Per-operation transaction data
    signal input ops[batchSize];
    signal input ilos[batchSize];
    signal input ihis[batchSize];
    signal input stakeIndices[batchSize];
    signal input durationIndices[batchSize];
    signal input timestamps[batchSize];
    
    // Per-operation witness data for account_lo
    signal input neighbors_lo[batchSize][64];
    signal input siblings_lo[batchSize][smtLevels];
    signal input isOld0_lo[batchSize];
    signal input oldKey_lo[batchSize];
    signal input oldValue_lo[batchSize];
    signal input arrIdx_lo[batchSize];
    
    // Per-operation witness data for account_hi
    signal input neighbors_hi[batchSize][64];
    signal input siblings_hi[batchSize][smtLevels];
    signal input isOld0_hi[batchSize];
    signal input oldKey_hi[batchSize];
    signal input oldValue_hi[batchSize];
    signal input arrIdx_hi[batchSize];
    
    // === Verify pubInputHash ===
    component pubHasher = Poseidon(5);
    pubHasher.inputs[0] <== oldRoot;
    pubHasher.inputs[1] <== newRoot;
    pubHasher.inputs[2] <== batchId;
    pubHasher.inputs[3] <== numOps;
    pubHasher.inputs[4] <== storageHash;
    pubInputHash === pubHasher.out;
    
    // === Verify storageHash (commitment to tx data) ===
    // Hash all tx fields: ops, ilos, ihis, stakeIndices, durationIndices, timestamps
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
    
    // Chain tx hashes together
    component chainHasher[batchSize];
    signal chainedHash[batchSize + 1];
    chainedHash[0] <== 0;
    
    for (var i = 0; i < batchSize; i++) {
        chainHasher[i] = Poseidon(2);
        chainHasher[i].inputs[0] <== chainedHash[i];
        chainHasher[i].inputs[1] <== txHashes[i];
        chainedHash[i + 1] <== chainHasher[i].out;
    }
    
    component finalStorageHash = Poseidon(3);
    finalStorageHash.inputs[0] <== batchId;
    finalStorageHash.inputs[1] <== numOps;
    finalStorageHash.inputs[2] <== chainedHash[batchSize];
    storageHash === finalStorageHash.out;
    
    // === Process Operations Sequentially ===
    signal roots[batchSize + 1];
    roots[0] <== oldRoot;
    
    component processors[batchSize];
    component shouldProcess[batchSize];
    
    for (var i = 0; i < batchSize; i++) {
        // Check if this slot is active (i < numOps)
        shouldProcess[i] = LessThan(8);
        shouldProcess[i].in[0] <== i;
        shouldProcess[i].in[1] <== numOps;
        
        processors[i] = ProcessEdgeOp(smtLevels);
        processors[i].currentRoot <== roots[i];
        
        // If beyond numOps, set op to 0 (NOP)
        processors[i].op <== shouldProcess[i].out * ops[i];
        processors[i].ilo <== ilos[i];
        processors[i].ihi <== ihis[i];
        
        // Account lo data
        for (var j = 0; j < 64; j++) {
            processors[i].neighbors_lo[j] <== neighbors_lo[i][j];
            processors[i].neighbors_hi[j] <== neighbors_hi[i][j];
        }
        for (var j = 0; j < smtLevels; j++) {
            processors[i].siblings_lo[j] <== siblings_lo[i][j];
            processors[i].siblings_hi[j] <== siblings_hi[i][j];
        }
        processors[i].isOld0_lo <== isOld0_lo[i];
        processors[i].isOld0_hi <== isOld0_hi[i];
        processors[i].oldKey_lo <== oldKey_lo[i];
        processors[i].oldKey_hi <== oldKey_hi[i];
        processors[i].oldValue_lo <== oldValue_lo[i];
        processors[i].oldValue_hi <== oldValue_hi[i];
        processors[i].arrIdx_lo <== arrIdx_lo[i];
        processors[i].arrIdx_hi <== arrIdx_hi[i];
        
        roots[i + 1] <== processors[i].newRoot;
    }
    
    // === Verify Final Root ===
    roots[batchSize] === newRoot;
}

//=============================================================================
// MAIN
//=============================================================================

component main {public [pubInputHash]} = ProcessBatch(10, 32);