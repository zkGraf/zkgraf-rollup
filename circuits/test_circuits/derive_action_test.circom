pragma circom 2.1.0;

include "circomlib/circuits/comparators.circom";
include "circomlib/circuits/bitify.circom";

include "templates/derive_action.circom";

template DeriveActionTest() {
    signal input oldArr[64];
    signal input element;
    signal input idx;
    signal input optype;

    signal output out[3]; // [doNop, doInsert, doRemove]

    component d = DeriveAction();
    for (var i = 0; i < 64; i++) d.oldArr[i] <== oldArr[i];
    d.element <== element;
    d.idx <== idx;
    d.optype <== optype;

    out[0] <== d.doNop;
    out[1] <== d.doInsert;
    out[2] <== d.doRemove;
}

component main = DeriveActionTest();
