// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/IFeeModel.sol";
import "../interfaces/ILoanRouterV2.sol";

/**
 * @title Ratio Fee Model
 * @author USD.AI Foundation
 */
contract RatioFeeModel is IFeeModel {
    /*------------------------------------------------------------------------*/
    /* Errors */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Invalid options
     */
    error InvalidOptions();

    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Fixed-point scale
     */
    uint256 internal constant FIXED_POINT_SCALE = 1e18;

    /*------------------------------------------------------------------------*/
    /* Structures */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Fee mode
     * @param Balance Compute fee as ratio of loan balance
     * @param Amount Compute fee as ratio of scaled amount
     */
    enum Mode {
        Balance,
        Amount
    }

    /**
     * @notice Decoded fee model options
     * @param mode Fee mode
     * @param rate Rate
     */
    struct Options {
        Mode mode;
        uint256 rate;
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
        return "RatioFeeModel";
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
        /* Decode and revert on malformed payloads */
        Options memory options = abi.decode(data, (Options));

        /* Reject rates above 100% which would compute a fee exceeding the basis */
        if (options.rate > FIXED_POINT_SCALE) revert InvalidOptions();
    }

    /**
     * @inheritdoc IFeeModel
     */
    function fee(
        ILoanRouterV2.LoanTermsV2 calldata,
        ILoanRouterV2.LoanState calldata state,
        bytes calldata options,
        uint256 scaledAmount
    ) external pure returns (uint256) {
        Options memory options_ = abi.decode(options, (Options));

        /* Return 0 if the rate is 0 */
        if (options_.rate == 0) return 0;

        /* Compute scaled fee, rounding up in favor of the fee recipient */
        if (options_.mode == Mode.Balance) {
            return Math.mulDiv(state.balance, options_.rate, FIXED_POINT_SCALE, Math.Rounding.Ceil);
        } else if (options_.mode == Mode.Amount) {
            return Math.mulDiv(scaledAmount, options_.rate, FIXED_POINT_SCALE, Math.Rounding.Ceil);
        }

        return 0;
    }
}
