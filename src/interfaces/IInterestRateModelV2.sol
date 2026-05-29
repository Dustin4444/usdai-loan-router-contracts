// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ILoanRouterV2.sol";

/**
 * @title Interest Rate Model V2 Interface
 * @author USD.AI Foundation
 */
interface IInterestRateModelV2 {
    /*------------------------------------------------------------------------*/
    /* API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Get interest rate model name
     * @return Interest rate model name
     */
    function INTEREST_RATE_MODEL_NAME() external view returns (string memory);

    /**
     * @notice Get interest rate model version
     * @return Interest rate model version
     */
    function INTEREST_RATE_MODEL_VERSION() external view returns (string memory);

    /**
     * @notice Validate model options
     * @param data Encoded model options
     */
    function validateOptions(
        bytes calldata data
    ) external pure;

    /**
     * @notice Compute repayment due for the current window
     * @param terms Loan terms
     * @param state Loan state
     * @param timestamp Reference timestamp
     * @return scaledPrincipalPayment Scaled principal payment due
     * @return scaledInterestPayment Scaled interest payment due
     * @return scaledTranchePrincipals Scaled principals per tranche
     * @return scaledTrancheInterests Scaled interests per tranche
     */
    function repayment(
        ILoanRouterV2.LoanTermsV2 calldata terms,
        ILoanRouterV2.LoanState calldata state,
        uint64 timestamp
    )
        external
        view
        returns (
            uint256 scaledPrincipalPayment,
            uint256 scaledInterestPayment,
            uint256[] memory scaledTranchePrincipals,
            uint256[] memory scaledTrancheInterests
        );

    /**
     * @notice Compute the grace period deadline for upcoming repayment
     * @param terms Loan terms
     * @param state Loan state
     * @return Grace period end timestamp
     */
    function gracePeriodEnd(
        ILoanRouterV2.LoanTermsV2 calldata terms,
        ILoanRouterV2.LoanState calldata state
    ) external view returns (uint64);
}
