// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {ReserveAccount} from "src/ReserveAccount.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract DeployReserveAccount is Deployer {
    function run(
        address borrower,
        address currencyToken,
        uint256 reservesRequired
    ) public broadcast useDeployment returns (address) {
        if (_deployment.reserveAccountBeacon == address(0x0)) revert MissingDependency();

        // Deploy ReserveAccount BeaconProxy
        BeaconProxy proxy = new BeaconProxy(
            _deployment.reserveAccountBeacon,
            abi.encodeWithSelector(ReserveAccount.initialize.selector, borrower, currencyToken, reservesRequired)
        );
        console.log("ReserveAccount proxy", address(proxy));

        return address(proxy);
    }
}
