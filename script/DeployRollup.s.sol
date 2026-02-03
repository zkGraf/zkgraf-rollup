// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Usage examples:
//
// 1) Local anvil (deploy Registry + Rollup):
//   forge script script/DeployRollup.s.sol:DeployRollup \
//     --rpc-url http://127.0.0.1:8545 --broadcast -vv \
//     --private-key $PRIVATE_KEY \
//     --sig "run()"
//
// 2) Sepolia (use existing VERIFIER, deploy new Registry):
//   export VERIFIER=0xYourGroth16Verifier
//   export STAKE_WEI=3000000000000000          # 0.003 ether
//   export WINDOW_DURATION=259200              # 3 days
//   export TX_FEE_WEI=10000000000000           # 0.00001 ether
//   forge script script/DeployRollup.s.sol:DeployRollup \
//     --rpc-url $SEPOLIA_RPC --broadcast -vv \
//     --private-key $PRIVATE_KEY
//
// 3) Use an existing Registry:
//   export REGISTRY=0xExistingRegistry
//   export VERIFIER=0xYourGroth16Verifier
//   forge script script/DeployRollup.s.sol:DeployRollup --rpc-url ... --broadcast -vv --private-key ...
//
// Env vars:
//   PRIVATE_KEY      (required when broadcasting unless you use --private-key flag)
//   VERIFIER         (required) address of deployed Groth16 verifier
//   REGISTRY         (optional) if unset/0, script deploys a new Registry
//   STAKE_WEI        (optional) defaults to 0.003 ether
//   WINDOW_DURATION  (optional) defaults to 3 days
//   TX_FEE_WEI       (optional) defaults to 0.00001 ether

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {Rollup} from "../src/Rollup.sol";
import {Registry} from "../src/Registry.sol";

contract DeployRollup is Script {
    function run() external returns (Registry registry, Rollup rollup) {
        // If you pass --private-key on the CLI, you can ignore PRIVATE_KEY env.
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) {
            // Foundry will still work if you supplied --private-key; this is just a nicer error.
            // If you're using --private-key, you can delete this check.
            // revert("Set PRIVATE_KEY env or pass --private-key");
        }

        address verifierAddr = vm.envAddress("VERIFIER");

        // Defaults match your earlier values
        uint256 stakeWei = vm.envOr("STAKE_WEI", uint256(0.003 ether));
        uint32 windowDuration = uint32(vm.envOr("WINDOW_DURATION", uint256(3 days)));

        address registryAddr = vm.envOr("REGISTRY", address(0));

        vm.startBroadcast();

        if (registryAddr == address(0)) {
            registry = new Registry();
            registryAddr = address(registry);
            console2.log("Deployed Registry:", registryAddr);
        } else {
            registry = Registry(registryAddr);
            console2.log("Using existing Registry:", registryAddr);
        }

        rollup = new Rollup(registryAddr, verifierAddr, stakeWei, windowDuration);

        vm.stopBroadcast();

        console2.log("Deployed Rollup:", address(rollup));
        console2.log("Verifier:", verifierAddr);
        console2.log("Stake (wei):", stakeWei);
        console2.log("Window duration (s):", windowDuration);

        return (registry, rollup);
    }
}
