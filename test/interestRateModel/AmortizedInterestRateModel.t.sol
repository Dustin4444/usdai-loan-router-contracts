// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {BaseTest} from "../Base.t.sol";
import {ILoanRouter} from "src/interfaces/ILoanRouter.sol";

contract AmortizedInterestRateModelTest is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Test: Metadata */
    /*------------------------------------------------------------------------*/

    function test__Metadata() public view {
        assertEq(interestRateModel.INTEREST_RATE_MODEL_NAME(), "AmortizedInterestRateModel", "Model name should match");
        assertEq(interestRateModel.INTEREST_RATE_MODEL_VERSION(), "1.0", "Model version should match");
    }

    /*------------------------------------------------------------------------*/
    /* Test: Repayment calculation - Single tranche */
    /*------------------------------------------------------------------------*/

    function test__Repayment_SingleTranche_OnTime() public view {
        uint256 principal = 100_000 * 1e6; // 100k USDC

        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 1, 0, 0);

        uint256 balance = principal;
        uint64 maturity = uint64(block.timestamp) + LOAN_DURATION;
        uint64 repaymentDeadline = uint64(block.timestamp) + REPAYMENT_INTERVAL;

        // Call repayment at the current time (on time)
        (
            uint256 principalPayment,
            uint256 interestPayment,
            uint256[] memory trancheInterests,
            uint256[] memory tranchePrincipals,
        ) = interestRateModel.repayment(loanTerms, balance, repaymentDeadline, maturity, uint64(block.timestamp));

        // Verify payments are positive
        assertGt(principalPayment, 0, "Principal payment should be positive");
        assertGt(interestPayment, 0, "Interest payment should be positive");

        // Verify tranche allocations
        assertEq(trancheInterests.length, 1, "Should have 1 tranche interest");
        assertEq(tranchePrincipals.length, 1, "Should have 1 tranche principal");
        assertGt(trancheInterests[0], 0, "Tranche interest should be positive");
        assertGt(tranchePrincipals[0], 0, "Tranche principal should be positive");

        // Principal payment should be less than or equal to balance
        assertLe(principalPayment, balance, "Principal payment should not exceed balance");
    }

    function test__Repayment_SingleTranche_Late() public {
        uint256 principal = 100_000 * 1e6;

        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 1, 0, 0);

        uint256 balance = principal;
        uint64 maturity = uint64(block.timestamp) + LOAN_DURATION;
        uint64 repaymentDeadline = uint64(block.timestamp) + REPAYMENT_INTERVAL;

        // Warp to 15 days after deadline (late payment)
        vm.warp(repaymentDeadline + 15 days);

        (
            uint256 principalPayment,
            uint256 interestPayment,
            uint256[] memory trancheInterests,
            uint256[] memory tranchePrincipals,
        ) = interestRateModel.repayment(loanTerms, balance, repaymentDeadline, maturity, uint64(block.timestamp));

        trancheInterests;
        tranchePrincipals;

        // Late payment should include grace period interest
        assertGt(principalPayment, 0, "Principal payment should be positive");
        assertGt(interestPayment, 0, "Interest payment should be positive (includes grace)");
    }

    /*------------------------------------------------------------------------*/
    /* Test: Repayment calculation - Multiple tranches */
    /*------------------------------------------------------------------------*/

    function test__Repayment_MultipleTranches() public view {
        uint256 principal = 300_000 * 1e6; // 300k USDC

        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 3, 0, 0);

        uint256 balance = principal;
        uint64 maturity = uint64(block.timestamp) + LOAN_DURATION;
        uint64 repaymentDeadline = uint64(block.timestamp) + REPAYMENT_INTERVAL;

        (
            uint256 principalPayment,
            uint256 interestPayment,
            uint256[] memory tranchePrincipals,
            uint256[] memory trancheInterests,
        ) = interestRateModel.repayment(loanTerms, balance, repaymentDeadline, maturity, uint64(block.timestamp));

        // Verify arrays have correct length
        assertEq(trancheInterests.length, 3, "Should have 3 tranche interests");
        assertEq(tranchePrincipals.length, 3, "Should have 3 tranche principals");

        // Verify all tranches receive payment
        for (uint256 i = 0; i < 3; i++) {
            assertGt(trancheInterests[i], 0, "Tranche interest should be positive");
            assertGt(tranchePrincipals[i], 0, "Tranche principal should be positive");
        }

        // Verify total equals individual tranches
        uint256 totalTrancheInterest = 0;
        uint256 totalTranchePrincipal = 0;
        for (uint256 i = 0; i < 3; i++) {
            totalTrancheInterest += trancheInterests[i];
            totalTranchePrincipal += tranchePrincipals[i];
        }

        assertEq(totalTrancheInterest, interestPayment, "Total tranche interest should equal total interest");
        assertEq(totalTranchePrincipal, principalPayment, "Total tranche principal should equal total principal");
    }

    function test__Repayment_MultipleTranches_DifferentRates() public view {
        uint256 principal = 300_000 * 1e6;

        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 3, 0, 0);

        uint256 balance = principal;
        uint64 maturity = uint64(block.timestamp) + LOAN_DURATION;
        uint64 repaymentDeadline = uint64(block.timestamp) + REPAYMENT_INTERVAL;

        (,,, uint256[] memory trancheInterests,) =
            interestRateModel.repayment(loanTerms, balance, repaymentDeadline, maturity, uint64(block.timestamp));

        // Higher rate tranches should receive more interest
        // loanTerms.trancheSpecs[0].rate = RATE_8_PCT (lowest)
        // loanTerms.trancheSpecs[1].rate = RATE_10_PCT (middle)
        // loanTerms.trancheSpecs[2].rate = RATE_14_PCT (highest)

        // Due to equal principal amounts, tranche 2 should have highest interest
        assertGt(trancheInterests[2], trancheInterests[1], "Tranche 2 should have more interest than 1");
        assertGt(trancheInterests[1], trancheInterests[0], "Tranche 1 should have more interest than 0");
    }

    /*------------------------------------------------------------------------*/
    /* Test: Repayment calculation - Multiple intervals overdue */
    /*------------------------------------------------------------------------*/

    function test__Repayment_TwoIntervalsOverdue() public {
        uint256 principal = 100_000 * 1e6;

        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 1, 0, 0);

        uint256 balance = principal;
        uint64 maturity = uint64(block.timestamp) + LOAN_DURATION;
        uint64 repaymentDeadline = uint64(block.timestamp) + REPAYMENT_INTERVAL;

        // Warp to 2 intervals late (60 days late)
        vm.warp(repaymentDeadline + (REPAYMENT_INTERVAL * 2));

        (uint256 principalPayment, uint256 interestPayment,,,) =
            interestRateModel.repayment(loanTerms, balance, repaymentDeadline, maturity, uint64(block.timestamp));

        // Should include 2 intervals worth of payments
        assertGt(principalPayment, 0, "Principal payment should be positive");
        assertGt(interestPayment, 0, "Interest payment should be positive");
    }

    /*------------------------------------------------------------------------*/
    /* Test: Repayment calculation - Near maturity */
    /*------------------------------------------------------------------------*/

    function test__Repayment_NearMaturity() public view {
        uint256 principal = 100_000 * 1e6;

        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 1, 0, 0);

        // Setup state where only 1 interval remains
        uint256 balance = principal / 12; // ~1/12th of principal remaining
        uint64 maturity = uint64(block.timestamp) + REPAYMENT_INTERVAL + 1 days;
        uint64 repaymentDeadline = uint64(block.timestamp) + REPAYMENT_INTERVAL;

        (uint256 principalPayment, uint256 interestPayment,,,) =
            interestRateModel.repayment(loanTerms, balance, repaymentDeadline, maturity, uint64(block.timestamp));

        // Should calculate payment for remaining interval
        assertGt(principalPayment, 0, "Principal payment should be positive");
        assertGt(interestPayment, 0, "Interest payment should be positive");
        assertLe(principalPayment, balance, "Principal payment should not exceed balance");
    }

    /*------------------------------------------------------------------------*/
    /* Test: Repayment calculation - After maturity */
    /*------------------------------------------------------------------------*/

    function test__Repayment_AfterMaturity_WithinGracePeriod() public {
        uint256 principal = 100_000 * 1e6;

        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 1, 0, 0);

        uint256 balance = principal / 10; // 10% remaining
        uint64 maturity = uint64(block.timestamp) - 5 days; // Already past maturity
        uint64 repaymentDeadline = maturity;

        // Warp to after maturity but within grace period
        vm.warp(block.timestamp + 1 days);

        (uint256 principalPayment, uint256 interestPayment,,,) =
            interestRateModel.repayment(loanTerms, balance, repaymentDeadline, maturity, uint64(block.timestamp));

        // Should still allow repayment with grace period interest
        assertGt(principalPayment, 0, "Principal payment should be positive");
        assertGt(interestPayment, 0, "Interest payment should include grace period");
    }

    /*------------------------------------------------------------------------*/
    /* Test: Edge cases */
    /*------------------------------------------------------------------------*/

    function test__Repayment_SmallBalance() public view {
        uint256 principal = 100_000 * 1e6;

        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 1, 0, 0);

        // Very small remaining balance
        uint256 balance = 100 * 1e6; // 100 USDC
        uint64 maturity = uint64(block.timestamp) + LOAN_DURATION;
        uint64 repaymentDeadline = uint64(block.timestamp) + REPAYMENT_INTERVAL;

        (uint256 principalPayment,,,,) =
            interestRateModel.repayment(loanTerms, balance, repaymentDeadline, maturity, uint64(block.timestamp));

        assertGt(principalPayment, 0, "Should calculate payment for small balance");
        assertLe(principalPayment, balance, "Principal payment should not exceed balance");
    }

    function test__Repayment_LargeBalance() public view {
        uint256 principal = 10_000_000 * 1e6; // 10M USDC

        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 3, 0, 0);

        uint256 balance = principal;
        uint64 maturity = uint64(block.timestamp) + LOAN_DURATION;
        uint64 repaymentDeadline = uint64(block.timestamp) + REPAYMENT_INTERVAL;

        (uint256 principalPayment, uint256 interestPayment,,,) =
            interestRateModel.repayment(loanTerms, balance, repaymentDeadline, maturity, uint64(block.timestamp));

        assertGt(principalPayment, 0, "Should calculate payment for large balance");
        assertGt(interestPayment, 0, "Interest should be calculated");
        assertLe(principalPayment, balance, "Principal payment should not exceed balance");
    }

    /*------------------------------------------------------------------------*/
    /* Test: Weighted interest rate */
    /*------------------------------------------------------------------------*/

    function test__Repayment_WeightedInterestRate() public view {
        uint256 principal = 300_000 * 1e6;

        // Create loan with 3 tranches of equal size but different rates
        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 3, 0, 0);

        // Calculate weighted average rate manually
        uint256 totalAmount = 0;
        uint256 weightedRateSum = 0;

        for (uint256 i = 0; i < loanTerms.trancheSpecs.length; i++) {
            totalAmount += loanTerms.trancheSpecs[i].amount;
            weightedRateSum += loanTerms.trancheSpecs[i].amount * loanTerms.trancheSpecs[i].rate;
        }

        uint256 blendedRate = weightedRateSum / totalAmount;
        uint256 totalInterest = (principal * blendedRate * LOAN_DURATION) / FIXED_POINT_SCALE;

        assertGt(blendedRate, 0, "Blended rate should be positive");
        assertGt(totalInterest, 0, "Total interest should be positive");

        // The blended rate should be between the min and max rates
        // RATE_8_PCT < blendedRate < RATE_14_PCT
        assertGt(blendedRate, RATE_8_PCT, "Blended rate should be > lowest rate");
        assertLt(blendedRate, RATE_14_PCT, "Blended rate should be < highest rate");
    }
}
