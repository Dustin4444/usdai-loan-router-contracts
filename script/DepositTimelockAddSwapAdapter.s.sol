// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import {DepositTimelock} from "src/DepositTimelock.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract DepositTimelockAddSwapAdapter is Deployer {
    function run(
        address token,
        address swapAdapter
    ) public broadcast useDeployment {
        DepositTimelock depositTimelock = DepositTimelock(_deployment.depositTimelock);

        if (depositTimelock.hasRole(0x00, msg.sender)) {
            depositTimelock.addSwapAdapter(token, swapAdapter);
        } else {
            console.log("\nCalldata");
            console.log("Target:   %s", address(depositTimelock));
            console.log("Calldata:");
            console.logBytes(abi.encodeWithSelector(DepositTimelock.addSwapAdapter.selector, token, swapAdapter));
        }
    }
}
