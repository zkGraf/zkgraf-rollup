// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Save as: test/Registry.t.sol
// Run: forge test -vv

import "forge-std/Test.sol";
import "../src/Registry.sol";

contract RegistryHarness is Registry {
    function setNextIdx(uint32 v) external {
        nextIdx = v;
    }
}

contract RegistryTest is Test {
    RegistryHarness internal registry;

    address internal alice;
    address internal bob;
    address internal charlie;

    function setUp() public {
        registry = new RegistryHarness();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
    }

    function testInitialState() public view {
        assertEq(registry.nextIdx(), 1);
        assertEq(registry.accountIdx(alice), 0);
        assertEq(registry.accountIdx(bob), 0);
        assertEq(registry.accountIdx(charlie), 0);
    }

    function testEnsureMyIdxCreatesIndexFirstTime() public {
        vm.expectEmit(true, true, false, true);
        emit Registry.AccountCreated(alice, 1);

        vm.prank(alice);
        uint32 idx = registry.ensureMyIdx();

        assertEq(idx, 1);
        assertEq(registry.accountIdx(alice), 1);
        assertEq(registry.idxToAccount(1), alice);
        assertEq(registry.nextIdx(), 2);
    }

    function testEnsureMyIdxReturnsSameIndexSecondTimeNoNewEvent() public {
        vm.prank(alice);
        uint32 first = registry.ensureMyIdx();

        uint32 nextBefore = registry.nextIdx();

        // record logs so we can assert no AccountCreated emitted
        vm.recordLogs();
        vm.prank(alice);
        uint32 second = registry.ensureMyIdx();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(first, second);
        assertEq(registry.accountIdx(alice), first);
        assertEq(registry.idxToAccount(first), alice);
        assertEq(registry.nextIdx(), nextBefore);

        // Ensure no AccountCreated was emitted on the second call
        bytes32 sig = keccak256("AccountCreated(address,uint32)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0) {
                assertTrue(logs[i].topics[0] != sig);
            }
        }
    }

    function testIndicesAreUniqueAndSequentialAcrossAccounts() public {
        vm.prank(alice);
        uint32 a = registry.ensureMyIdx();

        vm.prank(bob);
        uint32 b = registry.ensureMyIdx();

        vm.prank(charlie);
        uint32 c = registry.ensureMyIdx();

        assertEq(a, 1);
        assertEq(b, 2);
        assertEq(c, 3);

        assertEq(registry.accountIdx(alice), 1);
        assertEq(registry.accountIdx(bob), 2);
        assertEq(registry.accountIdx(charlie), 3);

        assertEq(registry.idxToAccount(1), alice);
        assertEq(registry.idxToAccount(2), bob);
        assertEq(registry.idxToAccount(3), charlie);

        assertEq(registry.nextIdx(), 4);
    }

    function testInverseMappingHoldsForManyAccounts() public {
        for (uint32 i = 0; i < 25; i++) {
            address u = makeAddr(string.concat("u", vm.toString(i)));
            vm.prank(u);
            uint32 idx = registry.ensureMyIdx();
            assertEq(registry.idxToAccount(idx), u);
            assertEq(registry.accountIdx(u), idx);
        }

        assertEq(registry.nextIdx(), 26);
    }

    function testIdxExhaustedRevertsWhenNextIdxIsMax() public {
        registry.setNextIdx(type(uint32).max);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Registry.IdxExhausted.selector));
        registry.ensureMyIdx();
    }

    function testCanIssueMaxMinusOneThenRevertOnMax() public {
        uint32 maxMinusOne = type(uint32).max - 1;
        registry.setNextIdx(maxMinusOne);

        vm.prank(alice);
        uint32 idx = registry.ensureMyIdx();

        assertEq(idx, maxMinusOne);
        assertEq(registry.accountIdx(alice), maxMinusOne);
        assertEq(registry.idxToAccount(maxMinusOne), alice);

        // nextIdx should now be max; next creation should revert
        assertEq(registry.nextIdx(), type(uint32).max);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Registry.IdxExhausted.selector));
        registry.ensureMyIdx();
    }
}
