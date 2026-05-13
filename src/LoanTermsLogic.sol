// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import "./interfaces/ILoanRouter.sol";

/**
 * @title Loan Terms Logic
 * @author USD.AI Foundation
 */
library LoanTermsLogic {
    /*------------------------------------------------------------------------*/
    /* Constant */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Loan terms hash with nonce EIP-712 typehash
     */
    bytes32 public constant LOAN_TERMS_V1_WITH_NONCE_TYPEHASH = keccak256(
        "LoanTermsWithNonce(LoanTerms loanTerms,uint256 nonce)FeeSpec(uint256 originationFee,uint256 exitFee)LoanTerms(uint64 expiration,address borrower,address currencyToken,address collateralToken,uint256 collateralTokenId,uint64 duration,uint64 repaymentInterval,address interestRateModel,uint256 gracePeriodRate,uint256 gracePeriodDuration,FeeSpec feeSpec,TrancheSpec[] trancheSpecs,bytes collateralWrapperContext,bytes options)TrancheSpec(address lender,uint256 amount,uint256 rate)"
    );

    /**
     * @notice Loan terms EIP-712 typehash
     */
    bytes32 public constant LOAN_TERMS_V1_TYPEHASH = keccak256(
        "LoanTerms(uint64 expiration,address borrower,address currencyToken,address collateralToken,uint256 collateralTokenId,uint64 duration,uint64 repaymentInterval,address interestRateModel,uint256 gracePeriodRate,uint256 gracePeriodDuration,FeeSpec feeSpec,TrancheSpec[] trancheSpecs,bytes collateralWrapperContext,bytes options)FeeSpec(uint256 originationFee,uint256 exitFee)TrancheSpec(address lender,uint256 amount,uint256 rate)"
    );

    /**
     * @notice Tranche spec EIP-712 typehash
     */
    bytes32 public constant LOAN_TERMS_V1_TRANCH_SPEC_TYPEHASH =
        keccak256("TrancheSpec(address lender,uint256 amount,uint256 rate)");

    /**
     * @notice Fee spec EIP-712 typehash
     */
    bytes32 public constant LOAN_TERMS_V1_FEE_SPEC_TYPEHASH =
        keccak256("FeeSpec(uint256 originationFee,uint256 exitFee)");

    /*------------------------------------------------------------------------*/
    /* Functions */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Hash loan terms with nonce
     * @param loanTerms Loan terms
     * @param nonce Nonce
     * @return Hash of loan terms with nonce
     */
    function hashLoanTermsWithNonce(
        ILoanRouter.LoanTerms calldata loanTerms,
        uint256 nonce
    ) external pure returns (bytes32) {
        bytes32 tranchesHash;
        bytes32 feeSpecHash;
        bytes32 loanTermsHash;

        {
            bytes32[] memory tranches = new bytes32[](loanTerms.trancheSpecs.length);
            for (uint256 i; i < loanTerms.trancheSpecs.length; i++) {
                tranches[i] = keccak256(
                    abi.encode(
                        LOAN_TERMS_V1_TRANCH_SPEC_TYPEHASH,
                        loanTerms.trancheSpecs[i].lender,
                        loanTerms.trancheSpecs[i].amount,
                        loanTerms.trancheSpecs[i].rate
                    )
                );
            }
            tranchesHash = keccak256(abi.encodePacked(tranches));
        }

        {
            feeSpecHash = keccak256(
                abi.encode(LOAN_TERMS_V1_FEE_SPEC_TYPEHASH, loanTerms.feeSpec.originationFee, loanTerms.feeSpec.exitFee)
            );
        }

        {
            loanTermsHash = keccak256(
                abi.encode(
                    LOAN_TERMS_V1_TYPEHASH,
                    loanTerms.expiration,
                    loanTerms.borrower,
                    loanTerms.currencyToken,
                    loanTerms.collateralToken,
                    loanTerms.collateralTokenId,
                    loanTerms.duration,
                    loanTerms.repaymentInterval,
                    loanTerms.interestRateModel,
                    loanTerms.gracePeriodRate,
                    loanTerms.gracePeriodDuration,
                    feeSpecHash,
                    tranchesHash,
                    keccak256(loanTerms.collateralWrapperContext),
                    keccak256(loanTerms.options)
                )
            );
        }

        return keccak256(abi.encode(LOAN_TERMS_V1_WITH_NONCE_TYPEHASH, loanTermsHash, nonce));
    }

    /**
     * @notice Validate loan terms
     * @param loanTerms Loan terms
     */
    function validateLoanTerms(
        ILoanRouter.LoanTerms calldata loanTerms
    ) external view {
        if (loanTerms.expiration < block.timestamp) revert ILoanRouter.InvalidLoanTerms("Expiration");
        if (loanTerms.currencyToken == address(0)) revert ILoanRouter.InvalidLoanTerms("Currency Token");
        if (loanTerms.collateralToken == address(0)) revert ILoanRouter.InvalidLoanTerms("Collateral Token");
        if (loanTerms.duration == 0) revert ILoanRouter.InvalidLoanTerms("Duration");
        if (loanTerms.repaymentInterval == 0) revert ILoanRouter.InvalidLoanTerms("Repayment Interval");
        if (loanTerms.repaymentInterval > loanTerms.duration) {
            revert ILoanRouter.InvalidLoanTerms("Repayment Interval");
        }
        if (loanTerms.duration % loanTerms.repaymentInterval != 0) {
            revert ILoanRouter.InvalidLoanTerms("Duration not multiple of Repayment Interval");
        }
        if (loanTerms.gracePeriodDuration > loanTerms.repaymentInterval) {
            revert ILoanRouter.InvalidLoanTerms("Grace Period Duration");
        }
        if (loanTerms.interestRateModel == address(0)) revert ILoanRouter.InvalidLoanTerms("Interest Rate Model");
        if (loanTerms.trancheSpecs.length == 0) revert ILoanRouter.InvalidLoanTerms("Tranche Specs");
        if (loanTerms.trancheSpecs.length > 32) revert ILoanRouter.InvalidLoanTerms("Tranche Specs");
        for (uint256 i; i < loanTerms.trancheSpecs.length; i++) {
            if (loanTerms.trancheSpecs[i].lender == address(0)) revert ILoanRouter.InvalidAddress();
            if (loanTerms.trancheSpecs[i].amount == 0) revert ILoanRouter.InvalidAmount();
            if (loanTerms.trancheSpecs[i].rate == 0) revert ILoanRouter.InvalidAmount();
        }
    }
}
