// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import {UniswapV3SwapAdapter} from "src/swapAdapters/UniswapV3SwapAdapter.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract DeployUniswapV3SwapAdapter is Deployer {
    function run(
        address swapRouter
    ) public broadcast returns (address) {
        // Deploy UniswapV3SwapAdapter
        UniswapV3SwapAdapter swapAdapter = new UniswapV3SwapAdapter(swapRouter);
        console.log("UniswapV3SwapAdapter", address(swapAdapter));

        return (address(swapAdapter));
    }
}
