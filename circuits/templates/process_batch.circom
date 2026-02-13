pragma circom 2.1.0;

include "circomlib/circuits/bitify.circom";
include "circomlib/circuits/comparators.circom";

include "templates/storage_hash.circom";
include "templates/field_to_bytes.circom";
include "templates/pubinputs_masked.circom";
include "templates/process_op.circom";


template ProcessBatch(batchSize, smtLevels) {
    // -----------------------------
    // Inputs (witness)
    // -----------------------------
    // Roots are Poseidon roots (field elements)
    signal input oldRootF;
    signal input newRootF;

    // Must match Solidity types in abi.encodePacked
    signal input batchId;   // uint64
    signal input start;     // uint32
    signal input numOps;    // uint32 (<= batchSize)

    // Fixed-size op arrays (must be full batchSize)
    signal input ops[batchSize];   // uint8 (0..255); convention: unused slots => 0
    signal input ilos[batchSize];  // uint32; unused slots => 0
    signal input ihis[batchSize];  // uint32; unused slots => 0

    // Per-op witnesses (as you sketched) — keep as-is for later wiring
    signal input neighbors_lo[batchSize][64];
    signal input oldDeg_lo[batchSize];
    signal input siblings_lo[batchSize][smtLevels];
    signal input isOld0_lo[batchSize];
    signal input oldKey_lo[batchSize];
    signal input oldValue_lo[batchSize];
    signal input arrIdx_lo[batchSize];

    signal input neighbors_hi[batchSize][64];
    signal input oldDeg_hi[batchSize];
    signal input siblings_hi[batchSize][smtLevels];
    signal input isOld0_hi[batchSize];
    signal input oldKey_hi[batchSize];
    signal input oldValue_hi[batchSize];
    signal input arrIdx_hi[batchSize];

    // -----------------------------
    // Public output (Groth16 public signal)
    // -----------------------------
    signal output pubInput0;

    // -----------------------------
    // Range checks / basic constraints
    // -----------------------------
    // Ensure numOps is uint32 and numOps <= batchSize
    component numOpsBits = Num2Bits(32);
    numOpsBits.in <== numOps;

    component numOpsLe = LessThan(32);
    numOpsLe.in[0] <== numOps;
    numOpsLe.in[1] <== batchSize + 1; // numOps <= batchSize
    numOpsLe.out === 1;

    // Ensure start is uint32, batchId is uint64 (types match Solidity packing)
    component startBits = Num2Bits(32);
    startBits.in <== start;

    component batchIdBits = Num2Bits(64);
    batchIdBits.in <== batchId;

    // Enforce unused tail slots are zero: for i >= numOps => ops[i]=ilos[i]=ihis[i]=0
    // This is IMPORTANT because StorageHash hashes all batchSize slots.
    component lt[batchSize];
    signal active[batchSize];

    for (var i = 0; i < batchSize; i++) {
        lt[i] = LessThan(32);
        lt[i].in[0] <== i;
        lt[i].in[1] <== numOps; // active if i < numOps

        // active bit (boolean)
        active[i] <== lt[i].out;
        active[i] * (active[i] - 1) === 0;

        // If not active, force zeros
        (1 - active[i]) * ops[i]  === 0;
        (1 - active[i]) * ilos[i] === 0;
        (1 - active[i]) * ihis[i] === 0;

        // Optional: also force witnesses to zero for unused slots to avoid “junk witnesses”
        // Uncomment if you want stricter hygiene:
        // (1 - active[i]) * arrIdx_lo[i] === 0;
        // (1 - active[i]) * arrIdx_hi[i] === 0;
        // (1 - active[i]) * isOld0_lo[i] === 0;
        // (1 - active[i]) * isOld0_hi[i] === 0;
        // (1 - active[i]) * oldKey_lo[i] === 0;
        // (1 - active[i]) * oldKey_hi[i] === 0;
        // (1 - active[i]) * oldValue_lo[i] === 0;
        // (1 - active[i]) * oldValue_hi[i] === 0;
        // for (var j = 0; j < 64; j++) {
        //   (1 - active[i]) * neighbors_lo[i][j] === 0;
        //   (1 - active[i]) * neighbors_hi[i][j] === 0;
        // }
        // for (var j = 0; j < smtLevels; j++) {
        //   (1 - active[i]) * siblings_lo[i][j] === 0;
        //   (1 - active[i]) * siblings_hi[i][j] === 0;
        // }
    }

    // -----------------------------
    // State transition logic
    // -----------------------------

    // Root chain
    signal r[batchSize + 1];
    r[0] <== oldRootF;

    component step[batchSize];

    for (var i = 0; i < batchSize; i++) {
        step[i] = ProcessOp(smtLevels);

        step[i].currentRoot <== r[i];
        step[i].op          <== ops[i];
        step[i].ilo         <== ilos[i];
        step[i].ihi         <== ihis[i];

        // lo witness
        for (var j = 0; j < 64; j++) step[i].neighbors_lo[j] <== neighbors_lo[i][j];
        step[i].oldDeg_lo <== oldDeg_lo[i];
        for (var j = 0; j < smtLevels; j++) step[i].siblings_lo[j] <== siblings_lo[i][j];
        step[i].isOld0_lo   <== isOld0_lo[i];
        step[i].oldKey_lo   <== oldKey_lo[i];
        step[i].oldValue_lo <== oldValue_lo[i];
        step[i].arrIdx_lo   <== arrIdx_lo[i];

        // hi witness
        for (var j = 0; j < 64; j++) step[i].neighbors_hi[j] <== neighbors_hi[i][j];
        step[i].oldDeg_hi <== oldDeg_hi[i];
        for (var j = 0; j < smtLevels; j++) step[i].siblings_hi[j] <== siblings_hi[i][j];
        step[i].isOld0_hi   <== isOld0_hi[i];
        step[i].oldKey_hi   <== oldKey_hi[i];
        step[i].oldValue_hi <== oldValue_hi[i];
        step[i].arrIdx_hi   <== arrIdx_hi[i];

        // advance root
        r[i + 1] <== step[i].newRoot;
    }

    // Final root must match claimed newRootF
    r[batchSize] === newRootF;


    // -----------------------------
    // storageHash = sha256(txDataFixed)
    // -----------------------------
    component sh = StorageHash(batchSize);
    for (var i = 0; i < batchSize; i++) {
        sh.ilo[i] <== ilos[i];
        sh.ihi[i] <== ihis[i];
        sh.op[i]  <== ops[i];
    }
    // sh.digest[256] are bits of SHA256(txDataFixed)

    // -----------------------------
    // pubInput0 = mask253(sha256(oldRootBytes32,newRootBytes32,batchId,start,numOps,storageHashBytes32))
    // -----------------------------
    component oldB = FieldToBytes();
    oldB.in <== oldRootF;

    component newB = FieldToBytes();
    newB.in <== newRootF;

    component pi = PubInputsMasked(); 
    for (var i = 0; i < 32; i++) {
        pi.oldRoot[i] <== oldB.out[i];
        pi.newRoot[i] <== newB.out[i];
    }
    // integers
    pi.batchId <== batchId;
    pi.start   <== start;
    pi.n       <== numOps;

    // pass storage digest bits (or bytes) depending on your pubinputs template signature:
    // Here we assume it accepts storageDigestBits[256] and does DigestBitsToBytes32 internally.
    for (var i = 0; i < 256; i++) {
        pi.storageDigest[i] <== sh.digest[i];
    }

    pubInput0 <== pi.input0;
}
