pragma circom 2.1.0;

include "templates/modify_array.circom";

template ModifyArrayTest() {
    signal input oldArr[64];
    signal input oldDeg;
    signal input element;
    signal input idx;
    signal input optype;

    signal output out[65];

    component m = ModifyArray();
    for (var i = 0; i < 64; i++) m.oldArr[i] <== oldArr[i];
    m.oldDeg <== oldDeg;
    m.element <== element;
    m.idx <== idx;
    m.optype <== optype;

    for (var i = 0; i < 64; i++) out[i] <== m.newArr[i];
    out[64] <== m.newDeg;
}

component main = ModifyArrayTest();
