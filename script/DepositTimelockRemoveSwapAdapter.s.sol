// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import {DepositTimelock} from "src/DepositTimelock.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract DepositTimelockRemoveSwapAdapter is Deployer {
    function run(
        address token
    ) public broadcast useDeployment {
        DepositTimelock depositTimelock = DepositTimelock(_deployment.depositTimelock);

        if (depositTimelock.hasRole(0x00, msg.sender)) {
            depositTimelock.removeSwapAdapter(token);
        } else {
            console.log("\nCalldata");
            console.log("Target:   %s", address(depositTimelock));
            console.log("Calldata:");
            console.logBytes(abi.encodeWithSelector(DepositTimelock.removeSwapAdapter.selector, token));
        }
    }
}
