// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import {USDaiSwapAdapter} from "src/swapAdapters/USDaiSwapAdapter.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract DeployUSDaiSwapAdapter is Deployer {
    function run(
        address usdai
    ) public broadcast returns (address) {
        // Deploy USDaiSwapAdapter
        USDaiSwapAdapter swapAdapter = new USDaiSwapAdapter(usdai);
        console.log("USDaiSwapAdapter", address(swapAdapter));

        return (address(swapAdapter));
    }
}
