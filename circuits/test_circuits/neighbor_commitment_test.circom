pragma circom 2.1.0;

include "templates/neighbor_commitment.circom";

template NeighborCommitmentTest() {
    signal input neighbors[64];
    signal input degree;
    signal output out[1];

    component nc = NeighborCommitment();
    for (var i = 0; i < 64; i++) nc.neighbors[i] <== neighbors[i];
    nc.degree <== degree;

    out[0] <== nc.out;
}

component main = NeighborCommitmentTest();
