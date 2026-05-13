// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {LoanRouter} from "src/LoanRouter.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract DeployLoanRouter is Deployer {
    function run(
        address depositTimelock,
        address collateralLiquidator,
        address collateralWrapper,
        address deployer,
        address admin,
        uint256 liquidationFeeRate
    ) public broadcast useDeployment returns (address) {
        // Deploy LoanRouter implementation
        LoanRouter loanRouterImpl = new LoanRouter(depositTimelock, collateralLiquidator, collateralWrapper);
        console.log("LoanRouter implementation", address(loanRouterImpl));

        // Deploy LoanRouter proxy
        TransparentUpgradeableProxy loanRouter = new TransparentUpgradeableProxy(
            address(loanRouterImpl),
            deployer,
            abi.encodeWithSelector(LoanRouter.initialize.selector, admin, admin, liquidationFeeRate)
        );
        console.log("LoanRouter proxy", address(loanRouter));

        _deployment.loanRouter = address(loanRouter);

        return (address(loanRouter));
    }
}
