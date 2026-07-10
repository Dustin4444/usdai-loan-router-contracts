// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {ReserveAccount} from "src/ReserveAccount.sol";
import {IReserveAccount} from "src/interfaces/IReserveAccount.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract UpgradeReserveAccountBeacon is Deployer {
    function run(
        address admin
    ) public broadcast useDeployment returns (address) {
        if (_deployment.reserveAccountBeacon == address(0x0)) revert MissingDependency();
        if (_deployment.loanRouterV2 == address(0x0)) revert MissingDependency();

        UpgradeableBeacon beacon = UpgradeableBeacon(_deployment.reserveAccountBeacon);

        // Deploy new ReserveAccount implementation
        ReserveAccount reserveAccountImpl = new ReserveAccount(admin, _deployment.loanRouterV2);
        console.log("ReserveAccount implementation", address(reserveAccountImpl));

        if (Ownable(address(beacon)).owner() == msg.sender) {
            /* Upgrade beacon */
            beacon.upgradeTo(address(reserveAccountImpl));
            console.log("Upgraded beacon %s implementation to: %s\n", address(beacon), address(reserveAccountImpl));
        } else {
            console.log("\nUpgrade calldata");
            console.log("Target:   %s", address(beacon));
            console.log("Calldata:");
            console.logBytes(abi.encodeWithSelector(UpgradeableBeacon.upgradeTo.selector, address(reserveAccountImpl)));
        }

        return address(reserveAccountImpl);
    }
}
