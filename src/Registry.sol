// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Registry {
    /// @notice 1-based; 0 = unset
    mapping(address => uint32) public accountIdx;
    uint32 public nextIdx = 1;

    event AccountCreated(address indexed owner, uint32 indexed idx);

    error IdxExhausted();

    /// @notice Create an idx for msg.sender if missing; returns existing otherwise.
    function ensureMyIdx() external returns (uint32 idx) {
        idx = accountIdx[msg.sender];
        if (idx != 0) return idx;

        if (nextIdx == type(uint32).max) revert IdxExhausted();

        idx = nextIdx++;
        accountIdx[msg.sender] = idx;

        emit AccountCreated(msg.sender, idx);
    }
}
