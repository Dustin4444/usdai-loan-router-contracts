// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {EscrowTimelock} from "src/EscrowTimelock.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract UpgradeEscrowTimelock is Deployer {
    function run(
        address depositToken,
        address depositor,
        address escrowAdmin
    ) public broadcast useDeployment returns (address) {
        // Deploy EscrowTimelock implementation
        EscrowTimelock escrowTimelockImpl = new EscrowTimelock(depositToken, depositor, escrowAdmin);
        console.log("EscrowTimelock implementation", address(escrowTimelockImpl));

        /* Lookup proxy admin */
        address proxyAdmin = address(uint160(uint256(vm.load(_deployment.escrowTimelock, ERC1967Utils.ADMIN_SLOT))));

        if (Ownable(proxyAdmin).owner() == msg.sender) {
            /* Upgrade Proxy */
            ProxyAdmin(proxyAdmin)
                .upgradeAndCall(
                    ITransparentUpgradeableProxy(_deployment.escrowTimelock), address(escrowTimelockImpl), ""
                );
            console.log(
                "Upgraded proxy %s implementation to: %s\n", _deployment.escrowTimelock, address(escrowTimelockImpl)
            );
        } else {
            console.log("\nUpgrade calldata");
            console.log("Target:   %s", proxyAdmin);
            console.log("Calldata:");
            console.logBytes(
                abi.encodeWithSelector(
                    ProxyAdmin.upgradeAndCall.selector,
                    ITransparentUpgradeableProxy(_deployment.escrowTimelock),
                    address(escrowTimelockImpl),
                    ""
                )
            );
        }

        return address(escrowTimelockImpl);
    }
}
