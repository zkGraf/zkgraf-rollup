pragma circom 2.1.0;

include "circomlib/circuits/bitify.circom";

// byte -> bits (MSB-first)
template ByteToBitsMSB() {
    signal input in;
    signal output out[8];
    component b = Num2Bits(8);
    b.in <== in;
    for (var i = 0; i < 8; i++) out[i] <== b.out[7 - i];
}

// uint32 -> 4 bytes big-endian
template U32ToBytesBE() {
    signal input in;
    signal output out[4];

    component b = Num2Bits(32);
    b.in <== in;

    component bn[4];
    for (var byte = 0; byte < 4; byte++) {
        bn[byte] = Bits2Num(8);
        for (var k = 0; k < 8; k++) bn[byte].in[k] <== b.out[byte*8 + k];
        out[3 - byte] <== bn[byte].out;
    }
}

// uint64 -> 8 bytes big-endian
template U64ToBytesBE() {
    signal input in;
    signal output out[8];

    component b = Num2Bits(64);
    b.in <== in;

    component bn[8];
    for (var byte = 0; byte < 8; byte++) {
        bn[byte] = Bits2Num(8);
        for (var k = 0; k < 8; k++) bn[byte].in[k] <== b.out[byte*8 + k];
        out[7 - byte] <== bn[byte].out;
    }
}

