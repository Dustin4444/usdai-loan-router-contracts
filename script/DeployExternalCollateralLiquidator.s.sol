// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ExternalCollateralLiquidator} from "src/liquidators/ExternalCollateralLiquidator.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract DeployExternalCollateralLiquidator is Deployer {
    function run(
        address deployer,
        address admin
    ) public broadcast useDeployment returns (address) {
        // Deploy ExternalCollateralLiquidator implementation
        ExternalCollateralLiquidator externalCollateralLiquidatorImpl = new ExternalCollateralLiquidator();
        console.log("ExternalCollateralLiquidator implementation", address(externalCollateralLiquidatorImpl));

        // Deploy ExternalCollateralLiquidator proxy
        TransparentUpgradeableProxy externalCollateralLiquidator = new TransparentUpgradeableProxy(
            address(externalCollateralLiquidatorImpl),
            deployer,
            abi.encodeWithSelector(ExternalCollateralLiquidator.initialize.selector, admin)
        );
        console.log("ExternalCollateralLiquidator proxy", address(externalCollateralLiquidator));

        _deployment.externalCollateralLiquidator = address(externalCollateralLiquidator);

        return (address(externalCollateralLiquidator));
    }
}
