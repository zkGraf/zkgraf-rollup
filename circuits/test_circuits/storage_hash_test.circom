pragma circom 2.1.0;

include "templates/storage_hash.circom";

// Wrapper / test harness for StorageHash(batchSize)
// Set BATCH_SIZE to your fixed size (e.g. 100 to match MAX_BATCH in Solidity)
template StorageHashTest(BATCH_SIZE) {
    signal input ilo[BATCH_SIZE];
    signal input ihi[BATCH_SIZE];
    signal input op[BATCH_SIZE];

    // Expose digest as a single output array (like your other tests)
    signal output out[256];

    component sh = StorageHash(BATCH_SIZE);

    for (var i = 0; i < BATCH_SIZE; i++) {
        sh.ilo[i] <== ilo[i];
        sh.ihi[i] <== ihi[i];
        sh.op[i]  <== op[i];
    }

    for (var i = 0; i < 256; i++) {
        out[i] <== sh.digest[i];
    }
}

// Choose your batch size here.
// For your Solidity contract MAX_BATCH=100, use 100.
component main = StorageHashTest(10);
