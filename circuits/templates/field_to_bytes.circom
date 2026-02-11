// templates/field_to_bytes.circom
pragma circom 2.1.0;

include "circomlib/circuits/bitify.circom";

// field element -> bytes32 big-endian
// Works for BN254 field elements because p < 2^254, so any field element fits in 254 bits.
// Encoding: out[0] is most-significant byte, out[31] least-significant byte.
template FieldToBytes() {
    signal input in;       // field element
    signal output out[32]; // bytes 0..255

    component b = Num2Bits(254);
    b.in <== in; // produces bits LSB-first

    component b2n[32];

    // Build bytes from LSB-first bits in little-endian byte order,
    // then place them into big-endian output.
    for (var byte = 0; byte < 32; byte++) {
        b2n[byte] = Bits2Num(8);

        for (var k = 0; k < 8; k++) {
            var bitIndex = byte * 8 + k; // LSB-first bit index
            if (bitIndex < 254) {
                b2n[byte].in[k] <== b.out[bitIndex];
            } else {
                // top 2 bits (254,255) are zero
                b2n[byte].in[k] <== 0;
            }
        }

        // byte 0 is least-significant -> goes to out[31] (big-endian)
        out[31 - byte] <== b2n[byte].out;
    }
}
