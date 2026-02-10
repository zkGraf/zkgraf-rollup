pragma circom 2.1.0;

include "circomlib/circuits/comparators.circom";
include "circomlib/circuits/bitify.circom";

//=============================================================================
// Derive effective action for a 64-slot DESC array with sentinel=0.
// Semantics: "always succeed" (impossible insert/remove becomes NOP).
//
// Inputs:
//  - oldArr[64], element, idx, optype (0/1/2)
//
// Outputs (one-hot):
//  - doNop/doInsert/doRemove
//
// Notes:
//  - Idempotent insert: if oldArr[idx]==element => NOP
//  - Idempotent remove: if oldArr[idx]!=element => NOP (idx NOT bound in this case)
//  - Real insert happens iff ALL hold:
//      * optype==1
//      * element != 0
//      * array not full (oldArr[63]==0)
//      * idx is correct insertion position in DESC order:
//          (idx==0 OR old[idx-1] > element) AND (element > old[idx])
//      * AND element is NOT already at old[idx] (via (1-eqAt))
//  - Real remove happens iff:
//      * optype==2 AND oldArr[idx]==element
//=============================================================================
template DeriveAction() {
    signal input oldArr[64];
    signal input element;
    signal input idx;
    signal input optype;     // 0=NOP, 1=ADD(insert), 2=REVOKE(remove)

    signal output doNop;
    signal output doInsert;
    signal output doRemove;

    var SENTINEL = 0;

    // --- constrain optype in {0,1,2}
    component is0 = IsEqual(); is0.in[0] <== optype; is0.in[1] <== 0;
    component is1 = IsEqual(); is1.in[0] <== optype; is1.in[1] <== 1;
    component is2 = IsEqual(); is2.in[0] <== optype; is2.in[1] <== 2;
    (is0.out + is1.out + is2.out) === 1;

    signal isInsertReq <== is1.out;
    signal isRemoveReq <== is2.out;

    // --- idx range [0..63]
    component idxBits = Num2Bits(6);
    idxBits.in <== idx;

    // --- idx==0?
    component idxIsZero = IsZero();
    idxIsZero.in <== idx;

    // --- mux oldAt = oldArr[idx] (quadratic-safe)
    component eqIdx[64];
    signal prodIdx[64];
    signal sumIdx[65];
    sumIdx[0] <== 0;

    for (var j = 0; j < 64; j++) {
        eqIdx[j] = IsEqual();
        eqIdx[j].in[0] <== idx;
        eqIdx[j].in[1] <== j;

        prodIdx[j] <== eqIdx[j].out * oldArr[j];
        sumIdx[j + 1] <== sumIdx[j] + prodIdx[j];
    }

    signal oldAt;
    oldAt <== sumIdx[64];

    // --- eqAt = (oldAt == element)
    component atEq = IsEqual();
    atEq.in[0] <== oldAt;
    atEq.in[1] <== element;
    signal eqAt <== atEq.out;

    // --- notFull = (oldArr[63] == 0)
    component lastIsZero = IsEqual();
    lastIsZero.in[0] <== oldArr[63];
    lastIsZero.in[1] <== SENTINEL;
    signal notFull <== lastIsZero.out;

    // --- element != 0
    component elemIsZero = IsEqual();
    elemIsZero.in[0] <== element;
    elemIsZero.in[1] <== 0;
    signal elemNonZero <== 1 - elemIsZero.out;
    

    // --- mux oldLeft = oldArr[idx-1] (quadratic-safe)
    component eqLeft[63];
    signal prodLeft[63];
    signal sumLeft[64];
    sumLeft[0] <== 0;

    for (var k = 0; k < 63; k++) {
        eqLeft[k] = IsEqual();
        eqLeft[k].in[0] <== idx;
        eqLeft[k].in[1] <== (k + 1);

        prodLeft[k] <== eqLeft[k].out * oldArr[k];
        sumLeft[k + 1] <== sumLeft[k] + prodLeft[k];
    }

    signal oldLeft;
    oldLeft <== sumLeft[63];

    // --- posOk for DESC insertion point when element absent:
    // oldLeft > element > oldAt
    component leftGT = LessThan(32);   // element < oldLeft
    leftGT.in[0] <== element;
    leftGT.in[1] <== oldLeft;

    component rightGT = LessThan(32);  // oldAt < element
    rightGT.in[0] <== oldAt;
    rightGT.in[1] <== element;

    signal leftOk <== idxIsZero.out + (1 - idxIsZero.out) * leftGT.out;
    signal posOk  <== leftOk * rightGT.out;

    // --- Effective actions (always succeed by degrading to NOP)
    // Real insert only when all conditions true
    signal canInsert <== (1 - eqAt) * notFull;
    signal canInsert2 <== canInsert * elemNonZero;
    signal canInsert3 <== canInsert2 * posOk;

    doInsert <== isInsertReq * canInsert3;

    // Real remove only when element matches at idx
    doRemove <== isRemoveReq * eqAt;

    //doRemove * (elemNonZero - 1) === 0;?


    // Everything else is NOP
    doNop <== 1 - doInsert - doRemove;

    // one-hot sanity (optional but nice)
    doInsert * (doInsert - 1) === 0;
    doRemove * (doRemove - 1) === 0;
    doNop    * (doNop    - 1) === 0;
    doInsert + doRemove + doNop === 1;
}
