// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {EscrowTimelock} from "src/EscrowTimelock.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract DeployEscrowTimelock is Deployer {
    function run(
        address deployer,
        address admin,
        address depositToken,
        address depositor,
        address escrowAdmin
    ) public broadcast useDeployment returns (address) {
        // Deploy EscrowTimelock implementation
        EscrowTimelock escrowTimelockImpl = new EscrowTimelock(depositToken, depositor, escrowAdmin);
        console.log("EscrowTimelock implementation", address(escrowTimelockImpl));

        // Deploy EscrowTimelock proxy
        TransparentUpgradeableProxy escrowTimelock = new TransparentUpgradeableProxy(
            address(escrowTimelockImpl), deployer, abi.encodeWithSelector(EscrowTimelock.initialize.selector, admin)
        );
        console.log("EscrowTimelock proxy", address(escrowTimelock));

        _deployment.escrowTimelock = address(escrowTimelock);

        return (address(escrowTimelock));
    }
}
