// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {DepositTimelock} from "src/DepositTimelock.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract UpgradeDepositTimelock is Deployer {
    function run() public broadcast useDeployment returns (address) {
        // Deploy DepositTimelock implementation
        DepositTimelock depositTimelockImpl = new DepositTimelock();
        console.log("DepositTimelock implementation", address(depositTimelockImpl));

        /* Lookup proxy admin */
        address proxyAdmin = address(uint160(uint256(vm.load(_deployment.depositTimelock, ERC1967Utils.ADMIN_SLOT))));

        if (Ownable(proxyAdmin).owner() == msg.sender) {
            /* Upgrade Proxy */
            ProxyAdmin(proxyAdmin)
                .upgradeAndCall(
                    ITransparentUpgradeableProxy(_deployment.depositTimelock), address(depositTimelockImpl), ""
                );
            console.log(
                "Upgraded proxy %s implementation to: %s\n", _deployment.depositTimelock, address(depositTimelockImpl)
            );
        } else {
            console.log("\nUpgrade calldata");
            console.log("Target:   %s", proxyAdmin);
            console.log("Calldata:");
            console.logBytes(
                abi.encodeWithSelector(
                    ProxyAdmin.upgradeAndCall.selector,
                    ITransparentUpgradeableProxy(_deployment.depositTimelock),
                    address(depositTimelockImpl),
                    ""
                )
            );
        }

        return address(depositTimelockImpl);
    }
}
