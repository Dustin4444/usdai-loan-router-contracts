// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {DepositTimelock} from "src/DepositTimelock.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract DeployDepositTimelock is Deployer {
    function run(
        address deployer,
        address admin
    ) public broadcast useDeployment returns (address) {
        // Deploy DepositTimelock implementation
        DepositTimelock depositTimelockImpl = new DepositTimelock();
        console.log("DepositTimelock implementation", address(depositTimelockImpl));

        // Deploy DepositTimelock proxy
        TransparentUpgradeableProxy depositTimelock = new TransparentUpgradeableProxy(
            address(depositTimelockImpl), deployer, abi.encodeWithSelector(DepositTimelock.initialize.selector, admin)
        );
        console.log("DepositTimelock proxy", address(depositTimelock));

        _deployment.depositTimelock = address(depositTimelock);

        return (address(depositTimelock));
    }
}
