// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Usage:
//   forge script script/DeployRegistry.s.sol:DeployRegistry \
//     --rpc-url $RPC --broadcast -vv --private-key $PRIVATE_KEY

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {Registry} from "../src/Registry.sol";

contract DeployRegistry is Script {
    function run() external returns (Registry registry) {
        vm.startBroadcast();
        registry = new Registry();
        vm.stopBroadcast();

        console2.log("Deployed Registry:", address(registry));
        return registry;
    }
}
