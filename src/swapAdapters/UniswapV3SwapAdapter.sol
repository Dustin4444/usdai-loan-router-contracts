// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapRouter02, IV3SwapRouter} from "../../src/interfaces/external/ISwapRouter02.sol";

import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";

/**
 * @title Uniswap V3 Swap Adapter
 * @author USD.AI Foundation
 */
contract UniswapV3SwapAdapter is ISwapAdapter {
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
    string public constant IMPLEMENTATION_NAME = "Uniswap V3 Swap Adapter";

    /**
     * @notice Path address size
     */
    uint256 internal constant PATH_ADDR_SIZE = 20;

    /**
     * @notice Path fee size
     */
    uint256 internal constant PATH_FEE_SIZE = 3;

    /**
     * @notice Path next offset
     */
    uint256 internal constant PATH_NEXT_OFFSET = PATH_ADDR_SIZE + PATH_FEE_SIZE;

    /*------------------------------------------------------------------------*/
    /* Errors */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Invalid amount
     */
    error InvalidAmount();

    /**
     * @notice Invalid path
     */
    error InvalidPath();

    /**
     * @notice Invalid path format
     */
    error InvalidPathFormat();

    /*------------------------------------------------------------------------*/
    /* Immutable state */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Swap router
     */
    ISwapRouter02 internal immutable _swapRouter;

    /*------------------------------------------------------------------------*/
    /* Constructor */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Uniswap V3 Swap Adapter Constructor
     * @param swapRouter_ Swap router
     */
    constructor(
        address swapRouter_
    ) {
        _swapRouter = ISwapRouter02(swapRouter_);
    }

    /*------------------------------------------------------------------------*/
    /* Modifiers */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Non-zero uint
     * @param value Value
     */
    modifier nonZeroUint(
        uint256 value
    ) {
        if (value == 0) revert InvalidAmount();
        _;
    }

    /**
     * @notice Valid swap in path
     * @param tokenInput Input token
     * @param tokenOutput Output token
     * @param path Path
     */
    modifier validSwapPath(
        address tokenInput,
        address tokenOutput,
        bytes calldata path
    ) {
        /* Decode input and output tokens */
        (address tokenInput_, address tokenOutput_) = _decodeInputAndOutputTokens(path);

        /* Validate input and output tokens */
        if (tokenInput_ != tokenInput || tokenOutput_ != tokenOutput) revert InvalidPath();

        _;
    }

    /*------------------------------------------------------------------------*/
    /* Helpers */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Decode input and output tokens
     * @param path Swap path
     * @return tokenInput Input token
     * @return tokenOutput Output token
     */
    function _decodeInputAndOutputTokens(
        bytes calldata path
    ) internal pure returns (address, address) {
        /* Validate path format */
        if (
            (path.length < PATH_ADDR_SIZE + PATH_FEE_SIZE + PATH_ADDR_SIZE)
                || ((path.length - PATH_ADDR_SIZE) % PATH_NEXT_OFFSET != 0)
        ) {
            revert InvalidPathFormat();
        }

        /* Get output token */
        address tokenOutput = address(bytes20(path[:PATH_ADDR_SIZE]));

        /* Calculate position of input token */
        uint256 numHops = (path.length - PATH_ADDR_SIZE) / PATH_NEXT_OFFSET;
        uint256 outputTokenIndex = numHops * PATH_NEXT_OFFSET;

        /* Get input token */
        address tokenInput = address(bytes20(path[outputTokenIndex:outputTokenIndex + PATH_ADDR_SIZE]));

        return (tokenInput, tokenOutput);
    }

    /*------------------------------------------------------------------------*/
    /* API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ISwapAdapter
     */
    function swap(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        bytes calldata path
    )
        external
        nonZeroUint(outputAmount)
        validSwapPath(inputToken, outputToken, path)
        returns (uint256, uint256, uint256)
    {
        /* Transfer token input from sender to this contract */
        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);

        /* Approve the router to spend token input */
        IERC20(inputToken).forceApprove(address(_swapRouter), inputAmount);

        /* Define swap params */
        IV3SwapRouter.ExactOutputParams memory params = IV3SwapRouter.ExactOutputParams({
            path: path, recipient: msg.sender, amountOut: outputAmount, amountInMaximum: inputAmount
        });

        /* Swap input token for base token */
        uint256 inputAmountUsed = _swapRouter.exactOutput(params);

        /* Calculate refund input amount */
        uint256 refundInputAmount = inputAmount - inputAmountUsed;

        /* Transfer excess token input from this contract to sender */
        if (refundInputAmount > 0) IERC20(inputToken).safeTransfer(msg.sender, refundInputAmount);

        /* Unset approval for the router to spend token input */
        IERC20(inputToken).forceApprove(address(_swapRouter), 0);

        /* Emit Swapped event */
        emit Swapped(inputToken, outputToken, inputAmount, outputAmount);

        return (outputAmount, refundInputAmount, 0);
    }
}
