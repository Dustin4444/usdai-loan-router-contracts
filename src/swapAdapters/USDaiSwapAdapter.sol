// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IUSDai} from "../interfaces/external/IUSDai.sol";

import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";

/**
 * @title USDai Swap Adapter
 * @author USD.AI Foundation
 */
contract USDaiSwapAdapter is ISwapAdapter {
    using SafeERC20 for IERC20;

    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Implementation version
     */
    string public constant IMPLEMENTATION_VERSION = "1.0";

    /**
     * @notice Implementation name
     */
    string public constant IMPLEMENTATION_NAME = "USDai Swap Adapter";

    /**
     * @notice USDai
     */
    IUSDai internal immutable USDai;

    /*------------------------------------------------------------------------*/
    /* Constructor */
    /*------------------------------------------------------------------------*/

    /**
     * @notice USDai Swap Adapter Constructor
     * @param usdai USDai address
     */
    constructor(
        address usdai
    ) {
        USDai = IUSDai(usdai);
    }

    /*------------------------------------------------------------------------*/
    /* API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ISwapAdapter
     */
    function swap(
        address,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        bytes calldata path
    ) external returns (uint256, uint256, uint256) {
        /* Transfer USDai from caller to this contract */
        IERC20(address(USDai)).safeTransferFrom(msg.sender, address(this), inputAmount);

        /* Withdraw USDai */
        uint256 withdrawAmount = USDai.withdraw(outputToken, inputAmount, outputAmount, msg.sender, path);

        /* Calculate refund output amount */
        uint256 refundOutputAmount = withdrawAmount - outputAmount;

        return (outputAmount, 0, refundOutputAmount);
    }
}
