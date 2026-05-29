// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title Loan Router V1 Interface (migration subset)
 * @author USD.AI Foundation
 */
interface ILoanRouterV1 {
    /*------------------------------------------------------------------------*/
    /* Structures */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Fee specification for loan
     */
    struct FeeSpec {
        uint256 originationFee;
        uint256 exitFee;
    }

    /**
     * @notice Tranche specification for loan
     */
    struct TrancheSpec {
        address lender;
        uint256 amount;
        uint256 rate;
    }

    /**
     * @notice Loan terms specification
     */
    struct LoanTerms {
        uint64 expiration;
        address borrower;
        address currencyToken;
        address collateralToken;
        uint256 collateralTokenId;
        uint64 duration;
        uint64 repaymentInterval;
        address interestRateModel;
        uint256 gracePeriodRate;
        uint256 gracePeriodDuration;
        FeeSpec feeSpec;
        TrancheSpec[] trancheSpecs;
        bytes collateralWrapperContext;
        bytes options;
    }

    /**
     * @notice Loan status
     * @param Uninitialized Loan has not been initialized
     * @param Active Loan is active
     * @param Repaid Loan has been repaid
     * @param Liquidated Loan has been liquidated
     * @param CollateralLiquidated Loan collateral has been liquidated
     * @param Migrated Loan has been migrated to a new router
     */
    enum LoanStatus {
        Uninitialized,
        Active,
        Repaid,
        Liquidated,
        CollateralLiquidated,
        Migrated
    }

    /*------------------------------------------------------------------------*/
    /* Getters */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Compute loan terms hash
     * @param loanTerms Loan terms
     * @return Hash of the loan terms
     */
    function loanTermsHash(
        LoanTerms calldata loanTerms
    ) external view returns (bytes32);

    /**
     * @notice Get loan state by loan terms hash
     * @param loanTermsHash_ Loan terms hash
     * @return status Loan status
     * @return maturity Loan maturity timestamp
     * @return repaymentDeadline Deadline for next repayment
     * @return scaledBalance Scaled loan balance (18 decimal)
     */
    function loanState(
        bytes32 loanTermsHash_
    ) external view returns (LoanStatus status, uint64 maturity, uint64 repaymentDeadline, uint256 scaledBalance);

    /*------------------------------------------------------------------------*/
    /* Migration API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Migrate this loan to a new router
     * @param loanTerms Loan terms
     */
    function migrateOut(
        LoanTerms calldata loanTerms
    ) external;
}
