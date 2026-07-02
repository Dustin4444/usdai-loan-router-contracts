// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {LoanRouterV2} from "src/LoanRouterV2.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract UpgradeLoanRouterV2 is Deployer {
    function run(
        address feeRecipient
    ) public broadcast useDeployment returns (address) {
        if (_deployment.collateralTimelock == address(0x0)) revert MissingDependency();
        if (_deployment.depositTimelock == address(0x0)) revert MissingDependency();
        if (_deployment.escrowTimelock == address(0x0)) revert MissingDependency();
        if (_deployment.loanRouterV2 == address(0x0)) revert MissingDependency();

        // Deploy LoanRouterV2 implementation
        LoanRouterV2 loanRouterImpl = new LoanRouterV2(
            feeRecipient, _deployment.collateralTimelock, _deployment.depositTimelock, _deployment.escrowTimelock
        );
        console.log("LoanRouterV2 implementation", address(loanRouterImpl));

        /* Lookup proxy admin */
        address proxyAdmin = address(uint160(uint256(vm.load(_deployment.loanRouterV2, ERC1967Utils.ADMIN_SLOT))));

        if (Ownable(proxyAdmin).owner() == msg.sender) {
            /* Upgrade Proxy */
            ProxyAdmin(proxyAdmin)
                .upgradeAndCall(ITransparentUpgradeableProxy(_deployment.loanRouterV2), address(loanRouterImpl), "");
            console.log("Upgraded proxy %s implementation to: %s\n", _deployment.loanRouterV2, address(loanRouterImpl));
        } else {
            console.log("\nUpgrade calldata");
            console.log("Target:   %s", proxyAdmin);
            console.log("Calldata:");
            console.logBytes(
                abi.encodeWithSelector(
                    ProxyAdmin.upgradeAndCall.selector,
                    ITransparentUpgradeableProxy(_deployment.loanRouterV2),
                    address(loanRouterImpl),
                    ""
                )
            );
        }

        return address(loanRouterImpl);
    }
}
