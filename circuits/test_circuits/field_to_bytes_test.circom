pragma circom 2.1.0;

include "templates/field_to_bytes.circom";

template FieldToBytesTest() {
    signal input in;
    signal output out[32];

    component f = FieldToBytes();
    f.in <== in;

    for (var i = 0; i < 32; i++) {
        out[i] <== f.out[i];
    }
}

component main = FieldToBytesTest();
