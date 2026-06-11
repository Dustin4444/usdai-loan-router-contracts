// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {CollateralTimelock} from "src/CollateralTimelock.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract DeployCollateralTimelock is Deployer {
    function run(
        address deployer,
        address admin
    ) public broadcast useDeployment returns (address) {
        // Deploy DepositTimelock implementation
        CollateralTimelock collateralTimelockImpl = new CollateralTimelock();
        console.log("CollateralTimelock implementation", address(collateralTimelockImpl));

        // Deploy DepositTimelock proxy
        TransparentUpgradeableProxy collateralTimelock = new TransparentUpgradeableProxy(
            address(collateralTimelockImpl),
            deployer,
            abi.encodeWithSelector(CollateralTimelock.initialize.selector, admin)
        );
        console.log("CollateralTimelock proxy", address(collateralTimelock));

        _deployment.collateralTimelock = address(collateralTimelock);

        return (address(collateralTimelock));
    }
}
