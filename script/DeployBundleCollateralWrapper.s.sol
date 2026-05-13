// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {BundleCollateralWrapper} from "src/collateralWrappers/BundleCollateralWrapper.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract DeployBundleCollateralWrapper is Deployer {
    function run(
        address deployer
    ) public broadcast useDeployment returns (address) {
        // Deploy BundleCollateralWrapper implementation
        BundleCollateralWrapper bundleCollateralWrapperImpl = new BundleCollateralWrapper();
        console.log("BundleCollateralWrapper implementation", address(bundleCollateralWrapperImpl));

        // Deploy BundleCollateralWrapper proxy
        TransparentUpgradeableProxy bundleCollateralWrapper =
            new TransparentUpgradeableProxy(address(bundleCollateralWrapperImpl), deployer, "");
        console.log("BundleCollateralWrapper proxy", address(bundleCollateralWrapper));

        _deployment.bundleCollateralWrapper = address(bundleCollateralWrapper);

        return (address(bundleCollateralWrapper));
    }
}
