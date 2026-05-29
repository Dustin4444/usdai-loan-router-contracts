// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {LoanRouterV2} from "src/LoanRouterV2.sol";

/**
 * @title LoanFixtures
 * @author USD.AI Foundation
 */
library LoanFixtures {
    /*------------------------------------------------------------------------*/
    /* Insurance fee constants */
    /*------------------------------------------------------------------------*/

    uint256 internal constant INSURANCE_ANNUAL_RATE = 0.015e18;

    /*------------------------------------------------------------------------*/
    /* Window variants (for parameterizing tests by schedule length) */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Window-variant selector. For 1095-day loans this produces 36 (Lower) or 37 (Upper) deadlines.
     */
    enum WindowVariant {
        Lower, // (e.g. 36 for 1095-day)
        Upper // (e.g. 37 for 1095-day)
    }

    /**
     * @notice Origination timestamp + repaymentDay recipe that produces a given window variant for the 1095-day
     * primary product. All recipes use `repaymentDay = 1`.
     * @param variant The desired window length
     * @return originationTs UTC timestamp to `vm.warp` to before calling `originate()`
     * @return repaymentDay  Always 1 for these recipes
     */
    function windowVariantRecipe1095(
        WindowVariant variant
    ) internal pure returns (uint64 originationTs, uint8 repaymentDay) {
        repaymentDay = 1;
        if (variant == WindowVariant.Lower) {
            /* 2024-02-01 00:00:00 UTC: D_0=1, R=1, advance to Mar 1; maturity = Jan 31, 2027; 35 anchors + maturity =
            36 */
            originationTs = 1706745600;
        } else {
            /* 2024-01-15 00:00:00 UTC: D_0=15, R=1, advance to Feb 1; maturity = Jan 14, 2027; 36 anchors + maturity =
            37 */
            originationTs = 1705276800;
        }
    }

    /*------------------------------------------------------------------------*/
    /* Tranche builders */
    /*------------------------------------------------------------------------*/

    function tranche(
        address lender,
        uint256 amount,
        uint256 rate
    ) internal pure returns (ILoanRouterV2.TrancheSpec memory) {
        return ILoanRouterV2.TrancheSpec({lender: lender, amount: amount, rate: rate});
    }

    function tranches1(
        ILoanRouterV2.TrancheSpec memory a
    ) internal pure returns (ILoanRouterV2.TrancheSpec[] memory arr) {
        arr = new ILoanRouterV2.TrancheSpec[](1);
        arr[0] = a;
    }

    function tranches2(
        ILoanRouterV2.TrancheSpec memory a,
        ILoanRouterV2.TrancheSpec memory b
    ) internal pure returns (ILoanRouterV2.TrancheSpec[] memory arr) {
        arr = new ILoanRouterV2.TrancheSpec[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function tranches3(
        ILoanRouterV2.TrancheSpec memory a,
        ILoanRouterV2.TrancheSpec memory b,
        ILoanRouterV2.TrancheSpec memory c
    ) internal pure returns (ILoanRouterV2.TrancheSpec[] memory arr) {
        arr = new ILoanRouterV2.TrancheSpec[](3);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
    }

    /*------------------------------------------------------------------------*/
    /* Struct builders */
    /*------------------------------------------------------------------------*/

    function makeTerms(
        address currencyToken,
        ILoanRouterV2.TrancheSpec[] memory trancheSpecs,
        bytes memory interestRateModelOptions
    ) internal pure returns (ILoanRouterV2.LoanTermsV2 memory terms) {
        terms.currencyToken = currencyToken;
        terms.trancheSpecs = trancheSpecs;
        terms.interestRateSpec.options = interestRateModelOptions;
    }

    function makeState(
        uint256 balance,
        uint16 repaymentCount,
        uint64 originationTimestamp
    ) internal pure returns (LoanRouterV2.LoanState memory state) {
        state.balance = balance;
        state.repaymentCount = repaymentCount;
        state.originationTimestamp = originationTimestamp;
    }

    /*------------------------------------------------------------------------*/
    /* Loan principal */
    /*------------------------------------------------------------------------*/

    function sumPrincipal(
        ILoanRouterV2.TrancheSpec[] memory trancheSpecs
    ) internal pure returns (uint256 total) {
        for (uint256 i; i < trancheSpecs.length; i++) {
            total += trancheSpecs[i].amount;
        }
    }
}
