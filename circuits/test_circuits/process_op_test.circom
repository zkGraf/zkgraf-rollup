pragma circom 2.1.0;

include "templates/process_op.circom";

// Wrapper: exposes ProcessOp as out[1] = newRoot
template ProcessOpTest(smtLevels) {
    signal input currentRoot;

    // 0=NOP, 1=ADD, 2=REVOKE
    signal input op;
    signal input ilo;
    signal input ihi;

    // ilo witness
    signal input neighbors_lo[64];
    signal input oldDeg_lo;
    signal input siblings_lo[smtLevels];
    signal input isOld0_lo;
    signal input oldKey_lo;
    signal input oldValue_lo;

    // ihi witness
    signal input neighbors_hi[64];
    signal input oldDeg_hi;
    signal input siblings_hi[smtLevels];
    signal input isOld0_hi;
    signal input oldKey_hi;
    signal input oldValue_hi;

    // ModifyArray idx hints
    signal input arrIdx_lo;
    signal input arrIdx_hi;

    signal output out[1];

    component p = ProcessOp(smtLevels);

    p.currentRoot <== currentRoot;

    p.op <== op;
    p.ilo <== ilo;
    p.ihi <== ihi;

    for (var i = 0; i < 64; i++) p.neighbors_lo[i] <== neighbors_lo[i];
    p.oldDeg_lo <== oldDeg_lo;
    for (var i = 0; i < smtLevels; i++) p.siblings_lo[i] <== siblings_lo[i];
    p.isOld0_lo <== isOld0_lo;
    p.oldKey_lo <== oldKey_lo;
    p.oldValue_lo <== oldValue_lo;

    for (var i = 0; i < 64; i++) p.neighbors_hi[i] <== neighbors_hi[i];
    p.oldDeg_hi <== oldDeg_hi;
    for (var i = 0; i < smtLevels; i++) p.siblings_hi[i] <== siblings_hi[i];
    p.isOld0_hi <== isOld0_hi;
    p.oldKey_hi <== oldKey_hi;
    p.oldValue_hi <== oldValue_hi;

    p.arrIdx_lo <== arrIdx_lo;
    p.arrIdx_hi <== arrIdx_hi;

    out[0] <== p.newRoot;
}

component main = ProcessOpTest(32);
