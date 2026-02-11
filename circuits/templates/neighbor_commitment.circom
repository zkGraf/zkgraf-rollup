pragma circom 2.1.0;

include "circomlib/circuits/poseidon.circom";

template NeighborCommitment() {
    signal input neighbors[64];
    signal input degree; // assumed to be the actaul degree. 
    signal output out;
    
    component h0 = Poseidon(16);
    component h1 = Poseidon(16);
    component h2 = Poseidon(16);
    component h3 = Poseidon(16);
    
    for (var i = 0; i < 16; i++) {
        h0.inputs[i] <== neighbors[i];
        h1.inputs[i] <== neighbors[16 + i];
        h2.inputs[i] <== neighbors[32 + i];
        h3.inputs[i] <== neighbors[48 + i];
    }
    
    component combine = Poseidon(5);
    combine.inputs[0] <== h0.out;
    combine.inputs[1] <== h1.out;
    combine.inputs[2] <== h2.out;
    combine.inputs[3] <== h3.out;
    combine.inputs[4] <== degree;
    out <== combine.out;
}

