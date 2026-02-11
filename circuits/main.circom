pragma circom 2.1.0;

include "process_batch.circom";

component main { public [pubInput0] } = ProcessBatch(3, 32);
