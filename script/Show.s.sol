// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.29;

import "forge-std/Script.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract Show is Deployer {
    function run() public {
        console.log("Printing deployments\n");
        console.log("Network: %s\n", _chainIdToNetwork[block.chainid]);

        /* Deserialize */
        _deserialize();

        console.log("loanRouter:                    %s", _deployment.loanRouter);
        console.log("depositTimelock:               %s", _deployment.depositTimelock);
        console.log("simpleInterestRateModel:       %s", _deployment.simpleInterestRateModel);
        console.log("amortizedInterestRateModel:    %s", _deployment.amortizedInterestRateModel);
        console.log("bundleCollateralWrapper:       %s", _deployment.bundleCollateralWrapper);
        console.log("externalCollateralLiquidator:  %s", _deployment.externalCollateralLiquidator);

        console.log("Printing deployments completed");
    }
}
