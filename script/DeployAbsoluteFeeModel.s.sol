// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import {AbsoluteFeeModel} from "src/fees/AbsoluteFeeModel.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract DeployAbsoluteFeeModel is Deployer {
    function run() public broadcast useDeployment returns (address) {
        // Deploy AbsoluteFeeModel
        AbsoluteFeeModel absoluteFeeModel = new AbsoluteFeeModel();
        console.log("AbsoluteFeeModel", address(absoluteFeeModel));

        _deployment.absoluteFeeModel = address(absoluteFeeModel);

        return (address(absoluteFeeModel));
    }
}
