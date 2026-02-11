pragma circom 2.1.0;

include "circomlib/circuits/comparators.circom";
include "circomlib/circuits/bitify.circom";
include "circomlib/circuits/mux1.circom";

template ModifyArray() {
    signal input oldArr[64];
    signal input oldDeg;
    signal input element;   // assumed uint32
    signal input idx;       // prover hint
    signal input optype;    // 0=NOP, 1=ADD(insert), 2=REVOKE(remove)

    signal output newArr[64];
    signal output newDeg;

    var SENTINEL = 0;

    // --- constrain optype in {0,1,2}
    component is0 = IsEqual(); is0.in[0] <== optype; is0.in[1] <== 0;
    component is1 = IsEqual(); is1.in[0] <== optype; is1.in[1] <== 1;
    component is2 = IsEqual(); is2.in[0] <== optype; is2.in[1] <== 2;
    (is0.out + is1.out + is2.out) === 1;

    signal doNop    <== is0.out;
    signal doInsert <== is1.out;
    signal doRemove <== is2.out;

    // --- idx range [0..63]
    component idxBits = Num2Bits(6);
    idxBits.in <== idx;

    // --- one-hot eqIdx[j] = (idx == j), plus oldAt = oldArr[idx]
    component eqIdx[64];
    signal sumIdx[65];
    sumIdx[0] <== 0;

    for (var j = 0; j < 64; j++) {
        eqIdx[j] = IsEqual();
        eqIdx[j].in[0] <== idx;
        eqIdx[j].in[1] <== j;

        sumIdx[j + 1] <== sumIdx[j] + eqIdx[j].out * oldArr[j];
    }

    signal oldAt;
    oldAt <== sumIdx[64];

    // --- oldLeft = oldArr[idx-1] for idx>0, else 0
    component idxIsZero = IsZero();
    idxIsZero.in <== idx;

    signal sumLeft[64];
    sumLeft[0] <== 0;
    for (var k = 0; k < 63; k++) {
        // idx == (k+1) is eqIdx[k+1].out
        sumLeft[k + 1] <== sumLeft[k] + eqIdx[k + 1].out * oldArr[k];
    }
    signal oldLeft;
    oldLeft <== sumLeft[63];

    // --- Determinism constraints (no “degrade to NOP”)
    // REMOVE requires oldAt == element
    component atEq = IsEqual();
    atEq.in[0] <== oldAt;
    atEq.in[1] <== element;
    doRemove * (1 - atEq.out) === 0;

    // INSERT requires "gap" at idx for descending order:
    // (idx==0 OR oldLeft > element) AND (element > oldAt)
    component leftGT = LessThan(32);   // element < oldLeft  (i.e., oldLeft > element)
    leftGT.in[0] <== element;
    leftGT.in[1] <== oldLeft;

    component rightGT = LessThan(32);  // oldAt < element    (i.e., element > oldAt)
    rightGT.in[0] <== oldAt;
    rightGT.in[1] <== element;

    signal leftOk <== idxIsZero.out + (1 - idxIsZero.out) * leftGT.out;
    signal posOk  <== leftOk * rightGT.out;

    doInsert * (1 - posOk) === 0;

    // Optional (recommended if 0 is sentinel and should never be inserted)
    // component elemIsZero = IsEqual();
    // elemIsZero.in[0] <== element;
    // elemIsZero.in[1] <== 0;
    // doInsert * elemIsZero.out === 0;

    // --- degree update (always succeed given contract checks)
    newDeg <== oldDeg + doInsert - doRemove;

    // --- compute before[i] = (i < idx)
    component isBefore[64];
    signal before[64];

    for (var i = 0; i < 64; i++) {
        isBefore[i] = LessThan(8);
        isBefore[i].in[0] <== i;
        isBefore[i].in[1] <== idx;
        before[i] <== isBefore[i].out; // i < idx
    }

    // --- prev/next arrays
    signal prev[64];
    signal next[64];

    prev[0] <== oldArr[0];
    for (var i = 1; i < 64; i++) prev[i] <== oldArr[i - 1];

    for (var i = 0; i < 63; i++) next[i] <== oldArr[i + 1];
    next[63] <== SENTINEL;

    // --- build newArr
    component ins1[64];
    component ins2[64];
    component rem1[64];
    component pickIR[64];
    component pickN[64];

    for (var i = 0; i < 64; i++) {
        // INSERT:
        // ins1 = at ? element : prev
        ins1[i] = Mux1();
        ins1[i].s <== eqIdx[i].out;
        ins1[i].c[0] <== prev[i];
        ins1[i].c[1] <== element;

        // ins2 = before ? old : ins1
        ins2[i] = Mux1();
        ins2[i].s <== before[i];
        ins2[i].c[0] <== ins1[i].out;
        ins2[i].c[1] <== oldArr[i];

        // REMOVE:
        // rem1 = before ? old : next
        rem1[i] = Mux1();
        rem1[i].s <== before[i];
        rem1[i].c[0] <== next[i];
        rem1[i].c[1] <== oldArr[i];

        // pick insert/remove if not nop
        pickIR[i] = Mux1();
        pickIR[i].s <== doInsert;
        pickIR[i].c[0] <== rem1[i].out; // doInsert=0 => remove
        pickIR[i].c[1] <== ins2[i].out; // doInsert=1 => insert

        // pick nop vs op
        pickN[i] = Mux1();
        pickN[i].s <== doNop;
        pickN[i].c[0] <== pickIR[i].out;
        pickN[i].c[1] <== oldArr[i];

        newArr[i] <== pickN[i].out;
    }
}
