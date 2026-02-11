pragma circom 2.1.0;
include "templates/process_op.circom";

include "templates/process_batch.circom"; // <-- put your ProcessBatch template in this file, or change include
// IMPORTANT: ProcessBatch requires ProcessOp(smtLevels) to be included somewhere reachable.
// If ProcessOp lives in another file, include it either here or inside process_batch.circom.
// Example:
// include "templates/process_op.circom";

template ProcessBatchTest(BATCH_SIZE, SMT_LEVELS) {
    signal input oldRootF;
    signal input newRootF;

    signal input batchId;
    signal input start;
    signal input numOps;

    signal input ops[BATCH_SIZE];
    signal input ilos[BATCH_SIZE];
    signal input ihis[BATCH_SIZE];

    signal input neighbors_lo[BATCH_SIZE][64];
    signal input oldDeg_lo[BATCH_SIZE];
    signal input siblings_lo[BATCH_SIZE][SMT_LEVELS];
    signal input isOld0_lo[BATCH_SIZE];
    signal input oldKey_lo[BATCH_SIZE];
    signal input oldValue_lo[BATCH_SIZE];
    signal input arrIdx_lo[BATCH_SIZE];

    signal input neighbors_hi[BATCH_SIZE][64];
    signal input oldDeg_hi[BATCH_SIZE];
    signal input siblings_hi[BATCH_SIZE][SMT_LEVELS];
    signal input isOld0_hi[BATCH_SIZE];
    signal input oldKey_hi[BATCH_SIZE];
    signal input oldValue_hi[BATCH_SIZE];
    signal input arrIdx_hi[BATCH_SIZE];

    signal output out[1];

    component pb = ProcessBatch(BATCH_SIZE, SMT_LEVELS);

    pb.oldRootF <== oldRootF;
    pb.newRootF <== newRootF;

    pb.batchId <== batchId;
    pb.start   <== start;
    pb.numOps  <== numOps;

    for (var i = 0; i < BATCH_SIZE; i++) {
        pb.ops[i]  <== ops[i];
        pb.ilos[i] <== ilos[i];
        pb.ihis[i] <== ihis[i];

        for (var j = 0; j < 64; j++) {
            pb.neighbors_lo[i][j] <== neighbors_lo[i][j];
            pb.neighbors_hi[i][j] <== neighbors_hi[i][j];
        }
        for (var j = 0; j < SMT_LEVELS; j++) {
            pb.siblings_lo[i][j] <== siblings_lo[i][j];
            pb.siblings_hi[i][j] <== siblings_hi[i][j];
        }

        pb.isOld0_lo[i]   <== isOld0_lo[i];
        pb.oldKey_lo[i]   <== oldKey_lo[i];
        pb.oldValue_lo[i] <== oldValue_lo[i];
        pb.arrIdx_lo[i]   <== arrIdx_lo[i];
        pb.oldDeg_lo[i] <== oldDeg_lo[i];

        pb.isOld0_hi[i]   <== isOld0_hi[i];
        pb.oldKey_hi[i]   <== oldKey_hi[i];
        pb.oldValue_hi[i] <== oldValue_hi[i];
        pb.arrIdx_hi[i]   <== arrIdx_hi[i];
        pb.oldDeg_hi[i] <== oldDeg_hi[i];
    }

    out[0] <== pb.pubInput0;
}

// Match these to your intended params.
// For quick tests keep batch small. For real: (100,160) etc.
component main = ProcessBatchTest(10, 32);
