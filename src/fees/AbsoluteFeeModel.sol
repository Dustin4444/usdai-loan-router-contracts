// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "../interfaces/IFeeModel.sol";
import "../interfaces/ILoanRouterV2.sol";

/**
 * @title Absolute Fee Model
 * @author USD.AI Foundation
 */
contract AbsoluteFeeModel is IFeeModel {
    /*------------------------------------------------------------------------*/
    /* Structures */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Decoded fee model options
     * @param amount Unscaled fee amount
     */
    struct Options {
        uint256 amount;
    }

    /*------------------------------------------------------------------------*/
    /* Constructor */
    /*------------------------------------------------------------------------*/

    constructor() {}

    /*------------------------------------------------------------------------*/
    /* API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IFeeModel
     */
    function FEE_MODEL_NAME() external pure returns (string memory) {
        return "AbsoluteFeeModel";
    }

    /**
     * @inheritdoc IFeeModel
     */
    function FEE_MODEL_VERSION() external pure returns (string memory) {
        return "1.0";
    }

    /**
     * @inheritdoc IFeeModel
     */
    function validateOptions(
        bytes calldata data
    ) external pure {
        /* Reverts if the data is not a valid Options struct */
        abi.decode(data, (Options));
    }

    /**
     * @inheritdoc IFeeModel
     */
    function fee(
        ILoanRouterV2.LoanTermsV2 calldata terms,
        ILoanRouterV2.LoanState calldata,
        bytes calldata options,
        uint256
    ) external view returns (uint256) {
        /* Compute scale factor */
        uint256 scaleFactor = 10 ** (18 - IERC20Metadata(terms.currencyToken).decimals());

        return abi.decode(options, (Options)).amount * scaleFactor;
    }
}
