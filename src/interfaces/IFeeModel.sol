// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ILoanRouterV2.sol";

/**
 * @title Fee Model Interface
 * @author USD.AI Foundation
 */
interface IFeeModel {
    /*------------------------------------------------------------------------*/
    /* API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Get fee model name
     * @return Fee model name
     */
    function FEE_MODEL_NAME() external view returns (string memory);

    /**
     * @notice Get fee model version
     * @return Fee model version
     */
    function FEE_MODEL_VERSION() external view returns (string memory);

    /**
     * @notice Validate model options
     * @param data Encoded model options
     */
    function validateOptions(
        bytes calldata data
    ) external pure;

    /**
     * @notice Compute fee owed under this model
     * @param terms Loan terms
     * @param state Loan state
     * @param options Encoded model options
     * @param scaledAmount Scaled amount
     * @return scaledFee Scaled fee amount
     */
    function fee(
        ILoanRouterV2.LoanTermsV2 calldata terms,
        ILoanRouterV2.LoanState calldata state,
        bytes calldata options,
        uint256 scaledAmount
    ) external view returns (uint256 scaledFee);
}
