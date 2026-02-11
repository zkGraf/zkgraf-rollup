pragma circom 2.1.0;

include "circomlib/circuits/comparators.circom";   // IsEqual, IsZero
include "circomlib/circuits/mux1.circom";          // Mux1
include "templates/modify_array.circom";
include "templates/neighbor_commitment.circom";
include "circomlib/circuits/smt/smtprocessor.circom";

template ProcessOp(smtLevels) {
    signal input currentRoot;
    signal output newRoot;

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

    // index hints for ModifyArray
    signal input arrIdx_lo;
    signal input arrIdx_hi;

    // -----------------------
    // op in {0,1,2}
    // -----------------------
    component is0 = IsEqual(); is0.in[0] <== op; is0.in[1] <== 0;
    component is1 = IsEqual(); is1.in[0] <== op; is1.in[1] <== 1;
    component is2 = IsEqual(); is2.in[0] <== op; is2.in[1] <== 2;
    (is0.out + is1.out + is2.out) === 1;

    signal doNop <== is0.out;

    // -----------------------
    // Neighbor arrays update (mutual)
    // -----------------------
    component modLo = ModifyArray();
    for (var i = 0; i < 64; i++) modLo.oldArr[i] <== neighbors_lo[i];
    modLo.oldDeg <== oldDeg_lo;
    modLo.element <== ihi;
    modLo.idx <== arrIdx_lo;
    modLo.optype <== op;

    component modHi = ModifyArray();
    for (var i = 0; i < 64; i++) modHi.oldArr[i] <== neighbors_hi[i];
    modHi.oldDeg <== oldDeg_hi;
    modHi.element <== ilo;
    modHi.idx <== arrIdx_hi;
    modHi.optype <== op;

    // -----------------------
    // New leaf values = NeighborCommitment(newArr, newDeg)
    // (Your NeighborCommitment now outputs 0 when degree==0.)
    // -----------------------
    component ncLo = NeighborCommitment();
    for (var i = 0; i < 64; i++) ncLo.neighbors[i] <== modLo.newArr[i];
    ncLo.degree <== modLo.newDeg;
    signal computedNewValue_lo <== ncLo.out;

    component ncHi = NeighborCommitment();
    for (var i = 0; i < 64; i++) ncHi.neighbors[i] <== modHi.newArr[i];
    ncHi.degree <== modHi.newDeg;
    signal computedNewValue_hi <== ncHi.out;

    // -----------------------
    // Choose SMT fnc per leaf
    // NOP: 00
    // else: if isOld0==1 -> INSERT (10), else UPDATE (01)
    // -----------------------
    // enabledOp = 1 - doNop
    signal enabledOp <== 1 - doNop;

    // fnc for lo
    // fncLo[0] = enabledOp * isOld0_lo           (1 for INSERT, 0 for UPDATE)
    // fncLo[1] = enabledOp * (1 - isOld0_lo)     (1 for UPDATE, 0 for INSERT)
    signal fncLo0 <== enabledOp * isOld0_lo;
    signal fncLo1 <== enabledOp * (1 - isOld0_lo);

    // fnc for hi
    signal fncHi0 <== enabledOp * isOld0_hi;
    signal fncHi1 <== enabledOp * (1 - isOld0_hi);

    // -----------------------
    // SMT update ilo then ihi
    // -----------------------
    component smt0 = SMTProcessor(smtLevels);
    smt0.oldRoot <== currentRoot;
    for (var i = 0; i < smtLevels; i++) smt0.siblings[i] <== siblings_lo[i];
    smt0.oldKey <== oldKey_lo;
    smt0.oldValue <== oldValue_lo;
    smt0.isOld0 <== isOld0_lo;
    smt0.newKey <== ilo;
    smt0.newValue <== computedNewValue_lo;
    smt0.fnc[0] <== fncLo0;
    smt0.fnc[1] <== fncLo1;

    signal root1 <== smt0.newRoot;

    component smt1 = SMTProcessor(smtLevels);
    smt1.oldRoot <== root1;
    for (var i = 0; i < smtLevels; i++) smt1.siblings[i] <== siblings_hi[i];
    smt1.oldKey <== oldKey_hi;
    smt1.oldValue <== oldValue_hi;
    smt1.isOld0 <== isOld0_hi;
    smt1.newKey <== ihi;
    smt1.newValue <== computedNewValue_hi;
    smt1.fnc[0] <== fncHi0;
    smt1.fnc[1] <== fncHi1;

    newRoot <== smt1.newRoot;

    // -----------------------
    // Optional: if not inserting, require witness key matches target key.
    // (SMTProcessor enforces oldKey==newKey when UPDATE, but oldKey is your witness input.
    //  We set newKey=ilo/ihi, so UPDATE implies oldKey must equal ilo/ihi anyway.)
    // -----------------------
}
