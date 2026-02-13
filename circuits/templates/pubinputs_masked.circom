pragma circom 2.1.0;

include "circomlib/circuits/bitify.circom";
include "circomlib/circuits/sha256/sha256.circom";

include "templates/bytes_utils.circom";


/// pubInput0 = mask253( sha256( abi.encodePacked(oldRoot32,newRoot32,batchIdU64,startU32,nU32,storageHash32) ) )
template PubInputsMasked() {
    signal input oldRoot[32];     // bytes
    signal input newRoot[32];     // bytes
    signal input batchId;         // uint64
    signal input start;           // uint32
    signal input n;               // uint32
    signal input storageDigest[256]; // bits from StorageHash

    signal output input0;
    signal output digest[256]; // optional: pubinputs digest bits

    // Range checks for old/new roots as bytes
    component ob[32];
    component nb[32];
    for (var i = 0; i < 32; i++) {
        ob[i] = Num2Bits(8); ob[i].in <== oldRoot[i];
        nb[i] = Num2Bits(8); nb[i].in <== newRoot[i];
    }

    // Range checks for ints
    component bidBits = Num2Bits(64); bidBits.in <== batchId;
    component stBits  = Num2Bits(32); stBits.in  <== start;
    component nBits   = Num2Bits(32); nBits.in   <== n;

    component bidBE = U64ToBytesBE(); bidBE.in <== batchId;
    component stBE  = U32ToBytesBE(); stBE.in  <== start;
    component nBE   = U32ToBytesBE(); nBE.in   <== n;

    // Convert storage digest bits -> storageHash bytes32
    component sd = DigestBitsToBytes32();
    for (var i = 0; i < 256; i++) sd.digest[i] <== storageDigest[i];

    // Preimage length = 32 + 32 + 8 + 4 + 4 + 32 = 112 bytes
    signal msg[112];

    for (var i = 0; i < 32; i++) msg[i]       <== oldRoot[i];
    for (var i = 0; i < 32; i++) msg[32 + i]  <== newRoot[i];
    for (var i = 0; i < 8;  i++) msg[64 + i]  <== bidBE.out[i];
    for (var i = 0; i < 4;  i++) msg[72 + i]  <== stBE.out[i];
    for (var i = 0; i < 4;  i++) msg[76 + i]  <== nBE.out[i];
    for (var i = 0; i < 32; i++) msg[80 + i]  <== sd.out[i];

    // bytes -> bits MSB-first
    signal bits[112 * 8];
    component bb[112];
    for (var i = 0; i < 112; i++) {
        bb[i] = ByteToBitsMSB();
        bb[i].in <== msg[i];
        for (var k = 0; k < 8; k++) bits[i*8 + k] <== bb[i].out[k];
    }

    component h = Sha256(112 * 8);
    for (var i = 0; i < 112 * 8; i++) h.in[i] <== bits[i];

    for (var i = 0; i < 256; i++) digest[i] <== h.out[i];

    // Mask to 253 bits: take 253 LSBs of the 256-bit big-endian digest
    signal lsb253[253];
    for (var i = 0; i < 253; i++) {
        lsb253[i] <== digest[255 - i]; // Bits2Num expects LSB-first
    }
    component b253 = Bits2Num(253);
    for (var i = 0; i < 253; i++) b253.in[i] <== lsb253[i];

    input0 <== b253.out;
}
