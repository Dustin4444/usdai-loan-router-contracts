// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {LoanRouterV2} from "src/LoanRouterV2.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract DeployLoanRouterV2 is Deployer {
    function run(
        address deployer,
        address admin,
        address feeRecipient,
        address loanRouterV1
    ) public broadcast useDeployment returns (address) {
        if (_deployment.collateralTimelock == address(0x0)) revert MissingDependency();
        if (_deployment.depositTimelock == address(0x0)) revert MissingDependency();
        if (_deployment.escrowTimelock == address(0x0)) revert MissingDependency();

        // Deploy LoanRouterV2 implementation
        LoanRouterV2 loanRouterImpl = new LoanRouterV2(
            feeRecipient,
            _deployment.collateralTimelock,
            _deployment.depositTimelock,
            _deployment.escrowTimelock,
            loanRouterV1
        );
        console.log("LoanRouterV2 implementation", address(loanRouterImpl));

        // Deploy LoanRouterV2 proxy
        TransparentUpgradeableProxy loanRouter = new TransparentUpgradeableProxy(
            address(loanRouterImpl), deployer, abi.encodeWithSelector(LoanRouterV2.initialize.selector, admin)
        );
        console.log("LoanRouterV2 proxy", address(loanRouter));

        _deployment.loanRouterV2 = address(loanRouter);

        return (address(loanRouter));
    }
}
