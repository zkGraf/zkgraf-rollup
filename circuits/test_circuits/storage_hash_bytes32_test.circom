pragma circom 2.1.0;

include "templates/storage_hash.circom";
include "templates/bytes_utils.circom"; // must contain BDigestBitsToBytes32itsToBytes()

template StorageHashBytes32Test(BATCH_SIZE) {
    signal input ilo[BATCH_SIZE];
    signal input ihi[BATCH_SIZE];
    signal input op[BATCH_SIZE];

    signal output outBytes[32]; // byte0..byte31

    component sh = StorageHash(BATCH_SIZE);
    for (var i = 0; i < BATCH_SIZE; i++) {
        sh.ilo[i] <== ilo[i];
        sh.ihi[i] <== ihi[i];
        sh.op[i]  <== op[i];
    }

    component db = DigestBitsToBytes32();
    for (var i = 0; i < 256; i++) {
        db.digest[i] <== sh.digest[i];
    }

    for (var i = 0; i < 32; i++) {
        outBytes[i] <== db.out[i];
    }
}

component main = StorageHashBytes32Test(3);
