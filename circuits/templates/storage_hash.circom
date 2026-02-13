pragma circom 2.1.0;

include "circomlib/circuits/bitify.circom";
include "circomlib/circuits/sha256/sha256.circom";

include "templates/bytes_utils.circom";

/// @notice Computes storageHash = sha256(txDataFixed)
/// where txDataFixed is exactly (batchSize * 9) bytes:
///   txDataFixed[9*i .. 9*i+8] = ilo[i](4 BE) | ihi[i](4 BE) | op[i](1 byte)
///
/// IMPORTANT: To match Solidity contract’s fixed array behavior,
/// represent "empty" slots as (ilo=0, ihi=0, op=0).
///
/// No manual padding here; circomlib Sha256 pads internally, matching Solidity sha256(bytes).
template StorageHash(batchSize) {
    signal input ilo[batchSize];  // uint32 each
    signal input ihi[batchSize];  // uint32 each
    signal input op[batchSize];   // uint8 each

    signal output digest[256];

    var nBytes = batchSize * 9;
    var nBits = nBytes * 8;

    // Declare all components up-front (initial scope)
    component iloBits[batchSize];
    component ihiBits[batchSize];
    component opBits[batchSize];

    component iloB[batchSize];
    component ihiB[batchSize];

    component bb[nBytes];

    signal txDataFixed[batchSize * 9];


    // Build txDataFixed bytes
    for (var i = 0; i < batchSize; i++) {
        // range checks
        iloBits[i] = Num2Bits(32);
        iloBits[i].in <== ilo[i];

        ihiBits[i] = Num2Bits(32);
        ihiBits[i].in <== ihi[i];

        opBits[i] = Num2Bits(8);
        opBits[i].in <== op[i];

        // BE bytes converters
        iloB[i] = U32ToBytesBE();
        iloB[i].in <== ilo[i];

        ihiB[i] = U32ToBytesBE();
        ihiB[i].in <== ihi[i];

        var base = 9 * i;

        // ilo(4)
        for (var j = 0; j < 4; j++) {
            txDataFixed[base + j] <== iloB[i].out[j];
        }
        // ihi(4)
        for (var j = 0; j < 4; j++) {
            txDataFixed[base + 4 + j] <== ihiB[i].out[j];
        }
        // op(1)
        txDataFixed[base + 8] <== op[i];
    }

    // bytes -> bits (MSB-first)
    signal bits[nBits];
    for (var i = 0; i < nBytes; i++) {
        bb[i] = ByteToBitsMSB();
        bb[i].in <== txDataFixed[i];

        for (var k = 0; k < 8; k++) {
            bits[i * 8 + k] <== bb[i].out[k];
        }
    }

    // hash raw bits; circomlib pads internally
    component h = Sha256(nBits);
    for (var i = 0; i < nBits; i++) {
        h.in[i] <== bits[i];
    }

    for (var i = 0; i < 256; i++) {
        digest[i] <== h.out[i];
    }
}
