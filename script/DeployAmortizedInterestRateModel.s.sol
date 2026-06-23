// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import {AmortizedInterestRateModel} from "src/rates/AmortizedInterestRateModel.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract DeployAmortizedInterestRateModel is Deployer {
    function run() public broadcast useDeployment returns (address) {
        // Deploy AmortizedInterestRateModel
        AmortizedInterestRateModel amortizedInterestRateModel = new AmortizedInterestRateModel();
        console.log("AmortizedInterestRateModel", address(amortizedInterestRateModel));

        _deployment.amortizedInterestRateModel = address(amortizedInterestRateModel);

        return (address(amortizedInterestRateModel));
    }
}
