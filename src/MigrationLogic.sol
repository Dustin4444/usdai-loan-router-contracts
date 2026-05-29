// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "./interfaces/ILoanRouterV2.sol";
import "./interfaces/ILoanRouterV1.sol";
import "./interfaces/ICollateralWrapper.sol";

import "./LoanLogicV2.sol";

/**
 * @title Migration Logic
 * @author USD.AI Foundation
 */
library MigrationLogic {
    /*------------------------------------------------------------------------*/
    /* Errors */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Invalid V2 origination timestamp
     */
    error InvalidOriginationTimestamp();

    /*------------------------------------------------------------------------*/
    /* Migration */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Validate migration from V1 to V2 loan terms
     * @param loanTermsV1 V1 loan terms
     * @param loanTermsV2 V2 loan terms
     * @param originationTimestampV2_ V2 origination timestamp override, 0 to derive from the last paid V1 deadline
     * @param loanRouterV1 LoanRouter V1 address
     * @return loanTermsHashV1 Loan terms hash V1
     * @return loanTermsHashV2 Loan terms hash V2
     * @return originationTimestampV2 V2 origination timestamp, the override when provided else the last paid V1
     * deadline
     * @return scaledBalanceV1 Scaled balance V1
     */
    function validateMigration(
        ILoanRouterV1.LoanTerms calldata loanTermsV1,
        ILoanRouterV2.LoanTermsV2 calldata loanTermsV2,
        uint64 originationTimestampV2_,
        address loanRouterV1
    ) external view returns (bytes32, bytes32, uint64, uint256) {
        /* Read V1 loan state */
        bytes32 loanTermsHashV1 = ILoanRouterV1(loanRouterV1).loanTermsHash(loanTermsV1);
        (ILoanRouterV1.LoanStatus statusV1, uint64 maturityV1, uint64 repaymentDeadlineV1, uint256 scaledBalanceV1) =
            ILoanRouterV1(loanRouterV1).loanState(loanTermsHashV1);

        /* Validate V1 loan is active */
        if (statusV1 != ILoanRouterV1.LoanStatus.Active) revert ILoanRouterV2.InvalidLoanState();

        /* Block migration if V1 is past maturity */
        if (uint64(block.timestamp) >= maturityV1) revert ILoanRouterV2.InvalidLoanTerms("Maturity");

        /* Require a whole-day repayment cadence */
        if (loanTermsV1.repaymentInterval % 86400 != 0) {
            revert ILoanRouterV2.InvalidLoanTerms("Repayment Interval");
        }

        /* Set origination timestamp */
        uint64 originationTimestampV2;
        if (originationTimestampV2_ != 0) {
            /* Validate origination timestamp */
            if (originationTimestampV2_ > block.timestamp) revert InvalidOriginationTimestamp();

            /* Set V2 origination timestamp */
            originationTimestampV2 = originationTimestampV2_;
        } else {
            /* Anchor V2 at the last paid V1 deadline (or V1 origination timestamp) */
            uint64 originationTimestampV1 = maturityV1 - loanTermsV1.duration;
            originationTimestampV2 =
                uint64(Math.max(originationTimestampV1, repaymentDeadlineV1 - loanTermsV1.repaymentInterval));
        }

        /* Read V2 currency decimals */
        uint8 loanTermsV2CurrencyDecimals = IERC20Metadata(loanTermsV2.currencyToken).decimals();

        /* Validate V2 currency decimals */
        if (loanTermsV2CurrencyDecimals != 18) revert ILoanRouterV2.InvalidLoanTerms("Currency Decimals");

        /* Validate V2 principal is compatible with V1 scaled balance */
        if (LoanLogicV2.computePrincipal(loanTermsV2) != scaledBalanceV1) {
            revert ILoanRouterV2.InvalidLoanTerms("Principal");
        }

        /* Resolve collateral: enumerate bundle or wrap single token ID into an array */
        bool isBundle = loanTermsV1.collateralWrapperContext.length > 0;
        address collateralToken;
        uint256[] memory collateralTokenIds;
        if (isBundle) {
            (collateralToken, collateralTokenIds) = ICollateralWrapper(loanTermsV1.collateralToken)
                .enumerate(loanTermsV1.collateralTokenId, loanTermsV1.collateralWrapperContext);
        } else {
            collateralToken = loanTermsV1.collateralToken;
            collateralTokenIds = new uint256[](1);
            collateralTokenIds[0] = loanTermsV1.collateralTokenId;
        }

        /* Validate V2 collateral token */
        if (loanTermsV2.collateralToken != collateralToken) revert ILoanRouterV2.InvalidLoanTerms("Collateral Token");

        /* Validate V2 collateral token IDs length */
        if (loanTermsV2.collateralTokenIds.length != collateralTokenIds.length) {
            revert ILoanRouterV2.InvalidLoanTerms("Collateral Token IDs Length");
        }

        /* Validate V2 collateral token IDs */
        for (uint256 i; i < loanTermsV2.collateralTokenIds.length; i++) {
            if (loanTermsV2.collateralTokenIds[i] != collateralTokenIds[i]) {
                revert ILoanRouterV2.InvalidLoanTerms("Collateral Token IDs");
            }
        }

        /* Validate the loan terms */
        LoanLogicV2.validateLoanTerms(loanTermsV2);

        /* Hash the final terms */
        return
            (
                loanTermsHashV1,
                LoanLogicV2.hashLoanTerms(abi.encode(loanTermsV2)),
                originationTimestampV2,
                scaledBalanceV1
            );
    }

    /**
     * @notice Migrate V1 loan collateral into V2
     * @param loanTermsV1 V1 loan terms
     * @param loanRouterV1 LoanRouter V1 address
     */
    function migrateLoanCollateral(
        ILoanRouterV1.LoanTerms calldata loanTermsV1,
        address loanRouterV1
    ) external {
        /* Migrate V1 collateral to V2 */
        ILoanRouterV1(loanRouterV1).migrateOut(loanTermsV1);

        /* Unwrap bundle if applicable */
        if (loanTermsV1.collateralWrapperContext.length > 0) {
            ICollateralWrapper(loanTermsV1.collateralToken)
                .unwrap(loanTermsV1.collateralTokenId, loanTermsV1.collateralWrapperContext);
        }
    }
}
