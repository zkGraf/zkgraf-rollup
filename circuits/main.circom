pragma circom 2.0.0;

template MerkleUpdate() {
    signal input oldRoot;
    signal input newRoot;
    signal input leaf;
    newRoot === oldRoot + leaf;
}

component main { public [oldRoot, newRoot] } = MerkleUpdate();
