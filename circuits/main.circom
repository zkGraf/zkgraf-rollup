pragma circom 2.1.0;

include "templates/process_batch.circom"; 

template Main(batchSize, smtLevels) {
    // public input
    signal input pubInput0;

    // private / witness inputs (match ProcessBatch inputs)
    signal input oldRootF;
    signal input newRootF;

    signal input batchId;
    signal input start;
    signal input numOps;

    signal input ops[batchSize];
    signal input ilos[batchSize];
    signal input ihis[batchSize];

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

    component pb = ProcessBatch(batchSize, smtLevels);

    pb.oldRootF <== oldRootF;
    pb.newRootF <== newRootF;
    pb.batchId  <== batchId;
    pb.start    <== start;
    pb.numOps   <== numOps;

    for (var i=0; i<batchSize; i++) {
        pb.ops[i]  <== ops[i];
        pb.ilos[i] <== ilos[i];
        pb.ihis[i] <== ihis[i];

        for (var j=0; j<64; j++) {
            pb.neighbors_lo[i][j] <== neighbors_lo[i][j];
            pb.neighbors_hi[i][j] <== neighbors_hi[i][j];
        }

        pb.oldDeg_lo[i] <== oldDeg_lo[i];
        pb.oldDeg_hi[i] <== oldDeg_hi[i];

        for (var j=0; j<smtLevels; j++) {
            pb.siblings_lo[i][j] <== siblings_lo[i][j];
            pb.siblings_hi[i][j] <== siblings_hi[i][j];
        }

        pb.isOld0_lo[i] <== isOld0_lo[i];
        pb.isOld0_hi[i] <== isOld0_hi[i];

        pb.oldKey_lo[i] <== oldKey_lo[i];
        pb.oldKey_hi[i] <== oldKey_hi[i];

        pb.oldValue_lo[i] <== oldValue_lo[i];
        pb.oldValue_hi[i] <== oldValue_hi[i];

        pb.arrIdx_lo[i] <== arrIdx_lo[i];
        pb.arrIdx_hi[i] <== arrIdx_hi[i];
    }

    // constrain: public input equals computed value
    pubInput0 === pb.pubInput0;
}

component main { public [pubInput0] } = Main(3, 32);
