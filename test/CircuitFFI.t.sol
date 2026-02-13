// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

contract CircuitFFITest is Test {
    function _hexNibble(uint8 c) internal pure returns (uint8) {
        // '0'..'9'
        if (c >= 48 && c <= 57) return c - 48;
        // 'a'..'f'
        if (c >= 97 && c <= 102) return c - 87;
        // 'A'..'F'
        if (c >= 65 && c <= 70) return c - 55;
        revert("bad hex");
    }

    function _isHex(uint8 c) internal pure returns (bool) {
        return (c >= 48 && c <= 57) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70);
    }

    /// @notice Extract first 64 hex chars from UTF-8 output and parse as bytes32.
    function _parseFirstBytes32Hex(bytes memory out) internal pure returns (bytes32) {
        uint256 acc = 0;
        uint256 count = 0;

        for (uint256 i = 0; i < out.length; i++) {
            uint8 c = uint8(out[i]);
            if (!_isHex(c)) continue;

            acc = (acc << 4) | uint256(_hexNibble(c));
            count++;

            if (count == 64) {
                return bytes32(acc);
            }
        }

        revert("hex too short");
    }

    function ffiStorageHashBytes32(
        uint32[3] memory ilo,
        uint32[3] memory ihi,
        uint8[3] memory op
    ) internal returns (bytes32) {
        string memory json = string.concat(
            "{",
            "\"ilo\":[", vm.toString(ilo[0]), ",", vm.toString(ilo[1]), ",", vm.toString(ilo[2]), "],",
            "\"ihi\":[", vm.toString(ihi[0]), ",", vm.toString(ihi[1]), ",", vm.toString(ihi[2]), "],",
            "\"op\":[",  vm.toString(uint256(op[0])), ",", vm.toString(uint256(op[1])), ",", vm.toString(uint256(op[2])), "]",
            "}"
        );

        string[] memory cmd = new string[](4);
        cmd[0] = "node";
        cmd[1] = "circuits/scripts/circuit-eval.mjs";
        cmd[2] = "storageHashBytes32";
        cmd[3] = json;

        bytes memory out = vm.ffi(cmd); // must be UTF-8
        return _decodeB64ToBytes32(string(out));

    }

    function buildTxDataFixed(
        uint32[3] memory ilo,
        uint32[3] memory ihi,
        uint8[3] memory op
    ) internal pure returns (bytes memory out) {
        out = new bytes(3 * 9);
        uint256 off = 0;

        for (uint256 i = 0; i < 3; i++) {
            uint32 a = ilo[i];
            uint32 b = ihi[i];

            out[off + 0] = bytes1(uint8(a >> 24));
            out[off + 1] = bytes1(uint8(a >> 16));
            out[off + 2] = bytes1(uint8(a >> 8));
            out[off + 3] = bytes1(uint8(a));

            out[off + 4] = bytes1(uint8(b >> 24));
            out[off + 5] = bytes1(uint8(b >> 16));
            out[off + 6] = bytes1(uint8(b >> 8));
            out[off + 7] = bytes1(uint8(b));

            out[off + 8] = bytes1(op[i]);
            off += 9;
        }
    }

    function test_storageHash_matches_circuit() public {
        uint32[3] memory ilo = [uint32(10), uint32(20), uint32(0)];
        uint32[3] memory ihi = [uint32(11), uint32(21), uint32(0)];
        uint8[3]  memory op  = [uint8(1),  uint8(2),  uint8(0)];

        bytes32 sol = sha256(buildTxDataFixed(ilo, ihi, op));
        bytes32 cir = ffiStorageHashBytes32(ilo, ihi, op);

        assertEq(cir, sol, "storageHash mismatch");
    }


    function _b64Index(bytes1 c) internal pure returns (uint8) {
    uint8 x = uint8(c);
    if (x >= 65 && x <= 90) return x - 65;        // A-Z -> 0..25
    if (x >= 97 && x <= 122) return x - 71;       // a-z -> 26..51
    if (x >= 48 && x <= 57) return x + 4;         // 0-9 -> 52..61
    if (c == bytes1("+")) return 62;
    if (c == bytes1("/")) return 63;
    revert("bad b64");
}

    function _decodeB64ToBytes32(string memory s) internal pure returns (bytes32 out) {
        bytes memory b = bytes(s);

        // trim whitespace
        uint256 l = 0;
        uint256 r = b.length;
        while (l < r && (b[l] == 0x20 || b[l] == 0x0a || b[l] == 0x0d || b[l] == 0x09)) l++;
        while (r > l && (b[r-1] == 0x20 || b[r-1] == 0x0a || b[r-1] == 0x0d || b[r-1] == 0x09)) r--;

        // For 32 bytes, base64 is typically 44 chars with "==" padding.
        require(r > l, "empty");
        uint256 n = r - l;
        require(n == 44 || n == 43 || n == 42, "b64 len"); // tolerate missing padding

        // decode into 32 bytes
        bytes memory outBytes = new bytes(32);
        uint256 outPos = 0;

        uint256 i = l;
        while (i < r) {
            // read 4 chars (pad with '=' if missing)
            bytes1 c0 = b[i++]; bytes1 c1 = (i < r) ? b[i++] : bytes1("=");
            bytes1 c2 = (i < r) ? b[i++] : bytes1("=");
            bytes1 c3 = (i < r) ? b[i++] : bytes1("=");

            uint256 v0 = _b64Index(c0);
            uint256 v1 = _b64Index(c1);

            uint256 v2 = (c2 == bytes1("=")) ? 0 : _b64Index(c2);
            uint256 v3 = (c3 == bytes1("=")) ? 0 : _b64Index(c3);

            uint256 triple = (v0 << 18) | (v1 << 12) | (v2 << 6) | v3;

            if (outPos < 32) outBytes[outPos++] = bytes1(uint8(triple >> 16));
            if (c2 != bytes1("=") && outPos < 32) outBytes[outPos++] = bytes1(uint8(triple >> 8));
            if (c3 != bytes1("=") && outPos < 32) outBytes[outPos++] = bytes1(uint8(triple));
        }

        require(outPos == 32, "b64 decoded len");

        assembly {
            out := mload(add(outBytes, 32))
        }
    }

}
