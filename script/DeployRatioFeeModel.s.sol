// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import {RatioFeeModel} from "src/fees/RatioFeeModel.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract DeployRatioFeeModel is Deployer {
    function run() public broadcast useDeployment returns (address) {
        // Deploy RatioFeeModel
        RatioFeeModel ratioFeeModel = new RatioFeeModel();
        console.log("RatioFeeModel", address(ratioFeeModel));

        _deployment.ratioFeeModel = address(ratioFeeModel);

        return (address(ratioFeeModel));
    }
}
