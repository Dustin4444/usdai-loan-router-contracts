// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ReserveAccount} from "src/ReserveAccount.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract DeployReserveAccountBeacon is Deployer {
    function run(
        address admin
    ) public broadcast useDeployment returns (address) {
        if (_deployment.loanRouterV2 == address(0x0)) revert MissingDependency();

        // Deploy ReserveAccount implementation
        ReserveAccount reserveAccountImpl = new ReserveAccount(admin, _deployment.loanRouterV2);
        console.log("ReserveAccount implementation", address(reserveAccountImpl));

        // Deploy UpgradeableBeacon
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(reserveAccountImpl), admin);
        console.log("ReserveAccount beacon", address(beacon));

        _deployment.reserveAccountBeacon = address(beacon);

        return (address(beacon));
    }
}
