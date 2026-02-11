pragma circom 2.1.0;

include "templates/pubinputs_masked.circom";

template PubInputsMaskedTest() {
    signal input oldRoot[32];
    signal input newRoot[32];
    signal input batchId;
    signal input start;
    signal input n;
    signal input storageDigest[256];

    signal output out[1];

    component pi = PubInputsMasked();

    for (var i = 0; i < 32; i++) {
        pi.oldRoot[i] <== oldRoot[i];
        pi.newRoot[i] <== newRoot[i];
    }
    pi.batchId <== batchId;
    pi.start   <== start;
    pi.n       <== n;

    for (var i = 0; i < 256; i++) {
        pi.storageDigest[i] <== storageDigest[i];
    }

    out[0] <== pi.input0;
}

component main = PubInputsMaskedTest();
