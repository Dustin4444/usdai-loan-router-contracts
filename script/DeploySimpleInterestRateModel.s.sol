// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import {SimpleInterestRateModel} from "src/rates/SimpleInterestRateModel.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract DeploySimpleInterestRateModel is Deployer {
    function run() public broadcast useDeployment returns (address) {
        // Deploy SimpleInterestRateModel
        SimpleInterestRateModel simpleInterestRateModel = new SimpleInterestRateModel();
        console.log("SimpleInterestRateModel", address(simpleInterestRateModel));

        _deployment.simpleInterestRateModel = address(simpleInterestRateModel);

        return (address(simpleInterestRateModel));
    }
}
