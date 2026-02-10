// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Save as: test/Rollup.t.sol
// Run: forge test -vv
//
// Updated to support txFee being a compile-time constant (or immutable) and to
// avoid depending on a specific getter name or constructor signature.
//
// Key changes:
// - Deploy Rollup via initcode + abi-encoded args (always encodes 5 args).
//   If your Rollup constructor now takes only 4 args, the extra arg is ignored.
// - Read fee via low-level staticcall, supporting BOTH `txFeeWei()` and `TX_FEE_WEI()`
// - Removed setTxFee() admin tests and the "changing tx fee breaks forging" test.
// - Avoid direct `rollup.txFeeWei()` calls anywhere.

import "forge-std/Test.sol";
import "../src/Rollup.sol";
import "../src/Registry.sol";

contract MockVerifier is IGroth16Verifier {
    bool public ok = true;

    function setOk(bool v) external {
        ok = v;
    }

    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[1] calldata)
        external
        view
        returns (bool)
    {
        return ok;
    }
}

/// @dev Malicious receiver attempting to re-enter withdrawAll() from receive()
contract Reenterer {
    Rollup public rollup;
    bool public tried;

    constructor(Rollup r) {
        rollup = r;
    }

    function depositToRollup() external payable {
        rollup.deposit{value: msg.value}();
    }

    function triggerWithdrawAll() external {
        rollup.withdrawAll();
    }

    receive() external payable {
        if (!tried) {
            tried = true;
            // should revert inside rollup due to nonReentrant; swallow revert
            (bool ok,) = address(rollup).call(abi.encodeWithSignature("withdrawAll()"));
            ok;
        }
    }
}

contract RollupTest is Test {
    Registry internal registry;
    MockVerifier internal verifier;
    Rollup internal rollup;

    address internal owner;
    address internal alice;
    address internal bob;
    address internal charlie;
    address internal batcher;

    uint256 internal STAKE = 0.003 ether;
    uint32 internal DUR = 3 days;

    // Used only as the 5th constructor arg in initcode deployment.
    // If Rollup no longer takes a fee arg, it will be ignored.
    uint256 internal DEPLOY_TXFEE = 0.00001 ether;

    // Actual fee read from Rollup after deployment (works for const/immutable/mutable)
    uint256 internal TXFEE;

    function setUp() public {
        owner = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        batcher = makeAddr("batcher");

        registry = new Registry();
        verifier = new MockVerifier();

        // Deploy Rollup without assuming constructor signature.
        // We always append 5 args: (registry, verifier, stake, duration, fee).
        // If your Rollup constructor is now only 4 args, the extra word is ignored.
        rollup = _deployRollup(address(registry), address(verifier), STAKE, DUR, DEPLOY_TXFEE);

        // Read fee from the contract (supports both txFeeWei() and TX_FEE_WEI()).
        TXFEE = _readTxFee(address(rollup));
        assertTrue(TXFEE != 0);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
        vm.deal(batcher, 100 ether);
    }

    // ------------------------------------------------------------
    // Deployment + fee getter helpers (robust to naming/signature)
    // ------------------------------------------------------------
    function _deployRollup(
        address registry_,
        address verifier_,
        uint256 stakeWei_,
        uint32 windowDuration_,
        uint256 txFeeWei_
    ) internal returns (Rollup r) {
        bytes memory init = abi.encodePacked(
            type(Rollup).creationCode, abi.encode(registry_, verifier_, stakeWei_, windowDuration_, txFeeWei_)
        );

        address deployed;
        assembly {
            deployed := create(0, add(init, 0x20), mload(init))
        }
        require(deployed != address(0), "ROLLUP_DEPLOY_FAIL");
        r = Rollup(deployed);
    }

    function _readTxFee(address rollupAddr) internal view returns (uint256 fee) {
        // Try `txFeeWei()`
        {
            (bool ok, bytes memory ret) = rollupAddr.staticcall(abi.encodeWithSignature("txFeeWei()"));
            if (ok && ret.length >= 32) return abi.decode(ret, (uint256));
        }
        // Try `TX_FEE_WEI()`
        {
            (bool ok, bytes memory ret) = rollupAddr.staticcall(abi.encodeWithSignature("TX_FEE_WEI()"));
            if (ok && ret.length >= 32) return abi.decode(ret, (uint256));
        }
        revert("TXFEE_GETTER_MISSING");
    }

    // ------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------
    function _order(address x, address y) internal pure returns (address lo, address hi) {
        return x < y ? (x, y) : (y, x);
    }

    function _ensureIdx(address u) internal {
        vm.prank(u);
        registry.ensureMyIdx();
    }

    function _ensureIdx2(address a, address b) internal {
        _ensureIdx(a);
        _ensureIdx(b);
    }

    // If your packed format is (ilo<<40)|(ihi<<8)|op, this matches.
    function _unpack(uint128 w) internal pure returns (uint32 ilo, uint32 ihi, uint8 op) {
        ilo = uint32(w >> 40);
        ihi = uint32(w >> 8);
        op = uint8(w);
    }

    function _openHandshake(address a, address b, bool payFromDepositA, bool payFromDepositB) internal {
        // a vouches
        vm.startPrank(a);
        if (payFromDepositA) {
            rollup.deposit{value: STAKE}();
            rollup.vouch{value: 0}(b);
        } else {
            rollup.vouch{value: STAKE}(b);
        }
        vm.stopPrank();

        // b revouches (opens window in your design)
        vm.startPrank(b);
        if (payFromDepositB) {
            rollup.deposit{value: STAKE}();
            rollup.revouch{value: 0}(a);
        } else {
            rollup.revouch{value: STAKE}(a);
        }
        vm.stopPrank();
    }

    function _finalizeAfterWindow(address a, address b) internal returns (uint32 txId, address lo, address hi) {
        _openHandshake(a, b, false, false);

        // Make sure both have idxs for finalize() in some repo variants
        _ensureIdx2(a, b);

        // Warp past window end using view helper if present, else use configured duration.
        (uint64 end, bool open) = rollup.windowEnd(a, b);
        if (open && end != 0) {
            vm.warp(uint256(end) + 1);
        } else {
            vm.warp(block.timestamp + DUR + 1);
        }

        (lo, hi) = _order(a, b);
        txId = rollup.nextTxId();

        vm.prank(a);
        rollup.finalize{value: TXFEE}(a, b);
    }

    // ------------------------------------------------------------
    // Constructor / admin
    // ------------------------------------------------------------
    function testConstructorState() public view {
        assertEq(rollup.owner(), owner);
        assertEq(rollup.stakeWei(), STAKE);
        assertEq(rollup.windowDuration(), DUR);
        assertEq(_readTxFee(address(rollup)), TXFEE);
        assertEq(address(rollup.registry()), address(registry));
        assertEq(address(rollup.verifier()), address(verifier));
    }

    function testOnlyOwnerSetters() public {
        rollup.setStake(0.01 ether);
        assertEq(rollup.stakeWei(), 0.01 ether);

        rollup.setDuration(7 days);
        assertEq(rollup.windowDuration(), 7 days);

        rollup.transferOwnership(alice);
        assertEq(rollup.owner(), alice);

        vm.expectRevert("NOT_OWNER");
        rollup.setStake(1);

        vm.prank(alice);
        rollup.setStake(0.02 ether);
        assertEq(rollup.stakeWei(), 0.02 ether);
    }

    // ------------------------------------------------------------
    // Deposit / withdrawal + reentrancy
    // ------------------------------------------------------------
    function testDepositCreditsBalance() public {
        vm.prank(alice);
        rollup.deposit{value: 1 ether}();
        assertEq(rollup.balances(alice), 1 ether);
    }

    function testDepositRevertsOnZero() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Rollup.BadValue.selector));
        rollup.deposit{value: 0}();
    }

    function testWithdrawWorks() public {
        vm.startPrank(alice);
        rollup.deposit{value: 2 ether}();

        uint256 before = alice.balance;
        rollup.withdraw(1 ether);

        assertEq(rollup.balances(alice), 1 ether);
        assertEq(alice.balance, before + 1 ether);
        vm.stopPrank();
    }

    function testWithdrawRevertsOnInsufficientBalance() public {
        vm.startPrank(alice);
        rollup.deposit{value: 0.5 ether}();
        vm.expectRevert(abi.encodeWithSelector(Rollup.InsufficientBalance.selector));
        rollup.withdraw(1 ether);
        vm.stopPrank();
    }

    function testWithdrawAllReentrancyGuardHolds() public {
        Reenterer r = new Reenterer(rollup);
        vm.deal(address(r), 10 ether);

        vm.prank(address(r));
        r.depositToRollup{value: 1 ether}();
        assertEq(rollup.balances(address(r)), 1 ether);

        vm.prank(address(r));
        r.triggerWithdrawAll();

        assertEq(rollup.balances(address(r)), 0);
        assertEq(address(r).balance, 10 ether);
        assertTrue(r.tried());
    }

    // ------------------------------------------------------------
    // _takeFunds behavior (deposit + msg.value)
    // ------------------------------------------------------------
    function testVouchUsesDepositBalanceWhenMsgValueZero() public {
        vm.startPrank(alice);
        rollup.deposit{value: STAKE}();
        rollup.vouch{value: 0}(bob);
        vm.stopPrank();

        assertEq(rollup.balances(alice), 0);
    }

    function testVouchUsesPartialDepositPlusMsgValue() public {
        uint256 part = STAKE / 2;

        vm.startPrank(alice);
        rollup.deposit{value: part}();
        rollup.vouch{value: STAKE - part}(bob);
        vm.stopPrank();

        assertEq(rollup.balances(alice), 0);
    }

    function testVouchCreditsExcessMsgValueToBalance() public {
        uint256 excess = 1 ether;

        vm.startPrank(alice);
        rollup.vouch{value: STAKE + excess}(bob);
        vm.stopPrank();

        assertEq(rollup.balances(alice), excess);
    }

    function testVouchRevertsIfInsufficientFunds() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Rollup.BadValue.selector));
        rollup.vouch{value: STAKE - 1}(bob);
    }

    // ------------------------------------------------------------
    // Handshake + window open
    // ------------------------------------------------------------
    function testVouchCreatesPairState() public {
        vm.prank(alice);
        rollup.vouch{value: STAKE}(bob);

        (address lo, address hi) = _order(alice, bob);
        (uint128 stakeLocked, uint32 durLocked, uint64 windowStart, bool loFunded, bool hiFunded) = rollup.pairs(lo, hi);

        assertEq(uint256(stakeLocked), STAKE);
        assertEq(durLocked, DUR);
        assertEq(windowStart, 0);

        if (alice == lo) {
            assertTrue(loFunded);
            assertFalse(hiFunded);
        } else {
            assertFalse(loFunded);
            assertTrue(hiFunded);
        }
    }

    function testRevouchOpensWindow() public {
        _openHandshake(alice, bob, false, false);

        (address lo, address hi) = _order(alice, bob);
        (,, uint64 windowStart, bool loFunded, bool hiFunded) = rollup.pairs(lo, hi);

        assertTrue(loFunded);
        assertTrue(hiFunded);
        assertTrue(windowStart != 0);

        (uint64 end, bool open) = rollup.windowEnd(alice, bob);
        assertTrue(open);
        assertTrue(end > windowStart);
    }

    function testCancelVouchOnlySoleFunderBeforeWindow() public {
        vm.prank(alice);
        rollup.vouch{value: STAKE}(bob);

        uint256 before = rollup.balances(alice);

        vm.prank(alice);
        rollup.cancelVouch(bob);

        assertEq(rollup.balances(alice), before + STAKE);

        (address lo, address hi) = _order(alice, bob);
        (uint128 stakeLocked,, uint64 ws,,) = rollup.pairs(lo, hi);
        assertEq(uint256(stakeLocked), 0);
        assertEq(ws, 0);
    }

    function testCancelVouchRevertsIfWindowOpen() public {
        _openHandshake(alice, bob, false, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Rollup.WindowAlreadyOpen.selector));
        rollup.cancelVouch(bob);
    }

    // ------------------------------------------------------------
    // Boundary tests (window end off-by-one)
    // ------------------------------------------------------------
    function testStealAndCloseBoundaryAtWindowEnd() public {
        _openHandshake(alice, bob, false, false);

        (uint64 end, bool open) = rollup.windowEnd(alice, bob);
        assertTrue(open && end != 0);

        // At exactly end, steal/close should still be allowed if your contract uses (timestamp > end) for PastWindow
        vm.warp(end);

        uint256 before = rollup.balances(alice);
        vm.prank(alice);
        rollup.steal(bob);
        assertEq(rollup.balances(alice), before + 2 * STAKE);

        // Re-open and test closeWithoutSteal at boundary
        _openHandshake(alice, bob, false, false);
        (end, open) = rollup.windowEnd(alice, bob);
        vm.warp(end);

        uint256 beforeA = rollup.balances(alice);
        uint256 beforeB = rollup.balances(bob);

        vm.prank(alice);
        rollup.closeWithoutSteal(bob);

        assertEq(rollup.balances(alice), beforeA + STAKE);
        assertEq(rollup.balances(bob), beforeB + STAKE);
    }

    function testFinalizeBoundaryAtWindowEnd() public {
        _openHandshake(alice, bob, false, false);
        _ensureIdx2(alice, bob);

        (uint64 end, bool open) = rollup.windowEnd(alice, bob);
        assertTrue(open && end != 0);

        vm.warp(end);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Rollup.WindowStillOpen.selector));
        rollup.finalize{value: TXFEE}(alice, bob);

        vm.warp(end + 1);
        vm.prank(alice);
        rollup.finalize{value: TXFEE}(alice, bob);

        (address lo, address hi) = _order(alice, bob);
        assertTrue(rollup.linked(lo, hi));
    }

    function testFinalizeRevertsIfBadFeeOrNotParticipant() public {
        _openHandshake(alice, bob, false, false);
        _ensureIdx2(alice, bob);

        (uint64 end, bool open) = rollup.windowEnd(alice, bob);
        if (open && end != 0) vm.warp(end + 1);
        else vm.warp(block.timestamp + DUR + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Rollup.BadValue.selector));
        rollup.finalize{value: TXFEE - 1}(alice, bob);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(Rollup.NotParticipant.selector));
        rollup.finalize{value: TXFEE}(alice, bob);
    }

    // ------------------------------------------------------------
    // linked truth + vouch/revoke gating
    // ------------------------------------------------------------
    function testLinkedTruthAndVouchGate() public {
        (uint32 txId, address lo, address hi) = _finalizeAfterWindow(alice, bob);

        assertTrue(rollup.linked(lo, hi));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Rollup.LinkAlreadyExists.selector));
        rollup.vouch{value: STAKE}(bob);

        // queue entry exists
        uint128 w = rollup.unforged(txId);
        assertTrue(w != 0);
        (,, uint8 op) = _unpack(w);
        assertEq(op, 1); // OP_ADD
    }

    function testRevokeGateAndEffect() public {
        (, address lo, address hi) = _finalizeAfterWindow(alice, bob);

        assertTrue(rollup.linked(lo, hi));

        // ensure idxs for revoke path in some repo variants
        _ensureIdx2(alice, bob);

        uint32 txId = rollup.nextTxId();

        vm.prank(bob);
        rollup.revoke{value: TXFEE}(alice);

        assertFalse(rollup.linked(lo, hi));

        // second revoke should be gated
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Rollup.LinkDoesNotExist.selector));
        rollup.revoke{value: TXFEE}(alice);

        uint128 w = rollup.unforged(txId);
        assertTrue(w != 0);
        (,, uint8 op) = _unpack(w);
        assertEq(op, 2); // OP_REVOKE
    }

    // ------------------------------------------------------------
    // submitBatch semantics
    // ------------------------------------------------------------
    function testSubmitBatchRevertsOnEmptyQueue() public {
        uint256[2] memory A;
        uint256[2][2] memory B;
        uint256[2] memory C;

        vm.prank(batcher);
        vm.expectRevert(); // accept any revert reason
        rollup.submitBatch(bytes32(uint256(1)), 1, A, B, C);
    }

    function testSubmitBatchRevertsOnZeroN() public {
        // enqueue one tx so empty-queue isn't the cause
        _finalizeAfterWindow(alice, bob);

        uint256[2] memory A;
        uint256[2][2] memory B;
        uint256[2] memory C;

        vm.prank(batcher);
        vm.expectRevert(abi.encodeWithSelector(Rollup.BadValue.selector));
        rollup.submitBatch(bytes32(uint256(2)), 0, A, B, C);
    }

    function testSubmitBatchRevertsOnTooLargeN() public {
        // enqueue one tx so empty-queue isn't the cause
        _finalizeAfterWindow(alice, bob);

        uint256[2] memory A;
        uint256[2][2] memory B;
        uint256[2] memory C;

        vm.prank(batcher);
        vm.expectRevert(abi.encodeWithSelector(Rollup.BadValue.selector));
        rollup.submitBatch(bytes32(uint256(3)), 101, A, B, C);
    }

    function testSubmitBatchRevertsWhenVerifierFails() public {
        // enqueue one tx so we get past empty-queue checks
        _finalizeAfterWindow(alice, bob);

        verifier.setOk(false);

        uint256[2] memory A;
        uint256[2][2] memory B;
        uint256[2] memory C;

        vm.prank(batcher);
        vm.expectRevert(abi.encodeWithSelector(Rollup.VerifyFail.selector));
        rollup.submitBatch(bytes32(uint256(4)), 1, A, B, C);
    }

    function testSubmitBatchUpdatesRootDeletesQueuePaysBatcher() public {
        // enqueue 2 ops: add then revoke
        _finalizeAfterWindow(alice, bob);
        _ensureIdx2(alice, bob);

        vm.prank(bob);
        rollup.revoke{value: TXFEE}(alice);

        uint32 start = rollup.lastForgedId() + 1;
        uint32 n = 2;

        bytes32 newRoot = keccak256("newRoot");

        uint256 feePoolBefore = rollup.feePool();
        uint256 balBefore = rollup.balances(batcher);
        uint64 batchIdBefore = rollup.batchId();

        uint256[2] memory A;
        uint256[2][2] memory B;
        uint256[2] memory C;

        vm.prank(batcher);
        rollup.submitBatch(newRoot, n, A, B, C);

        assertEq(rollup.latestGraphRoot(), newRoot);
        assertEq(rollup.batchId(), batchIdBefore + 1);
        assertEq(rollup.lastForgedId(), start + (n - 1));

        // unforged entries deleted
        assertEq(rollup.unforged(start), 0);
        assertEq(rollup.unforged(start + 1), 0);

        // paid (use TXFEE read from contract)
        assertEq(rollup.balances(batcher), balBefore + uint256(n) * TXFEE);
        assertEq(rollup.feePool(), feePoolBefore - uint256(n) * TXFEE);
    }

    // ------------------------------------------------------------
    // Revoke gating semantics sanity
    // ------------------------------------------------------------
    function testRevokeIsGatedByLinkedNotByParticipation() public {
        _ensureIdx(charlie);
        _ensureIdx(bob);

        // not linked => must revert
        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(Rollup.LinkDoesNotExist.selector));
        rollup.revoke{value: TXFEE}(bob);
    }
}
