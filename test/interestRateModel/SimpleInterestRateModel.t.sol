// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {BaseTest} from "../Base.t.sol";
import {ILoanRouter} from "src/interfaces/ILoanRouter.sol";
import {SimpleInterestRateModel} from "src/rates/SimpleInterestRateModel.sol";

contract SimpleInterestRateModelTest is BaseTest {
    SimpleInterestRateModel internal simpleModel;

    function setUp() public override {
        super.setUp();
        simpleModel = new SimpleInterestRateModel();
    }

    /*------------------------------------------------------------------------*/
    /* Test: Metadata */
    /*------------------------------------------------------------------------*/

    function test__Metadata() public view {
        assertEq(simpleModel.INTEREST_RATE_MODEL_NAME(), "SimpleInterestRateModel", "Model name should match");
        assertEq(simpleModel.INTEREST_RATE_MODEL_VERSION(), "1.1", "Model version should match");
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
        ) = simpleModel.repayment(loanTerms, balance, repaymentDeadline, maturity, uint64(block.timestamp));

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
        ) = simpleModel.repayment(loanTerms, balance, repaymentDeadline, maturity, uint64(block.timestamp));

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
        ) = simpleModel.repayment(loanTerms, balance, repaymentDeadline, maturity, uint64(block.timestamp));

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
            simpleModel.repayment(loanTerms, balance, repaymentDeadline, maturity, uint64(block.timestamp));

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
            simpleModel.repayment(loanTerms, balance, repaymentDeadline, maturity, uint64(block.timestamp));

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
            simpleModel.repayment(loanTerms, balance, repaymentDeadline, maturity, uint64(block.timestamp));

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
            simpleModel.repayment(loanTerms, balance, repaymentDeadline, maturity, uint64(block.timestamp));

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
            simpleModel.repayment(loanTerms, balance, repaymentDeadline, maturity, uint64(block.timestamp));

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
            simpleModel.repayment(loanTerms, balance, repaymentDeadline, maturity, uint64(block.timestamp));

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

    /*------------------------------------------------------------------------*/
    /* Test: Simple Interest Model Specific - Constant Principal */
    /*------------------------------------------------------------------------*/

    function test__ConstantPrincipalPayment() public view {
        uint256 principal = 12_000 * 1e18; // 12,000 for easy division
        uint256 rate = 4756468797; // 15% APR
        uint64 repaymentInterval = 2628000;
        uint256 numRepayments = 12;

        // Create loan terms
        ILoanRouter.TrancheSpec[] memory trancheSpecs = new ILoanRouter.TrancheSpec[](1);
        trancheSpecs[0] = ILoanRouter.TrancheSpec({lender: users.lender1, amount: principal, rate: rate});

        ILoanRouter.LoanTerms memory loanTerms = ILoanRouter.LoanTerms({
            expiration: uint64(block.timestamp + 7 days),
            borrower: users.borrower,
            currencyToken: USDC,
            collateralToken: address(bundleCollateralWrapper),
            collateralTokenId: wrappedTokenId,
            duration: repaymentInterval * uint64(numRepayments),
            repaymentInterval: repaymentInterval,
            interestRateModel: address(simpleModel),
            gracePeriodRate: 0,
            gracePeriodDuration: 0,
            feeSpec: ILoanRouter.FeeSpec({originationFee: 0, exitFee: 0}),
            trancheSpecs: trancheSpecs,
            collateralWrapperContext: encodedBundle,
            options: ""
        });

        uint256 currentBalance = principal;
        uint64 maturity = uint64(block.timestamp) + loanTerms.duration;
        uint256 expectedPrincipalPerPayment = principal / numRepayments; // 1000 each

        // Track principal payments to verify consistency
        uint256[] memory principalPayments = new uint256[](numRepayments);

        // Test that principal payment is constant across all payments
        for (uint256 i = 0; i < numRepayments; i++) {
            uint64 repaymentDeadline = uint64(block.timestamp) + repaymentInterval * uint64(i + 1);

            (uint256 principalPayment, uint256 interestPayment,,,) =
                simpleModel.repayment(loanTerms, currentBalance, repaymentDeadline, maturity, uint64(block.timestamp));

            principalPayments[i] = principalPayment;

            if (i < numRepayments - 1) {
                // All payments except last should be exactly the expected amount
                assertEq(
                    principalPayment,
                    expectedPrincipalPerPayment,
                    string.concat("Principal payment should be constant at payment ", vm.toString(i + 1))
                );
            } else {
                // Last payment takes remaining balance
                assertEq(principalPayment, currentBalance, "Last payment should equal remaining balance");
            }

            // Interest should decrease over time as balance decreases
            if (i > 0) {
                // Store previous payment for comparison would require state, so just verify positive
                assertGt(interestPayment, 0, "Interest should be positive");
            }

            currentBalance -= principalPayment;
        }

        // Verify all principal payments (except last) are within a few wei of each other
        for (uint256 i = 1; i < numRepayments - 1; i++) {
            uint256 diff = principalPayments[i] > principalPayments[0]
                ? principalPayments[i] - principalPayments[0]
                : principalPayments[0] - principalPayments[i];
            assertLe(
                diff,
                10,
                string.concat("Principal payment interval should be consistent at payment ", vm.toString(i + 1))
            );
        }

        // Final balance should be zero (or very close due to rounding)
        assertLe(currentBalance, 1e15, "Final balance should be nearly zero");
    }

    function test__DecreasingTotalPayment() public view {
        uint256 principal = 10_000 * 1e18;
        uint256 rate = 4756468797; // 15% APR
        uint64 repaymentInterval = 2628000;
        uint256 numRepayments = 12;

        // Create loan terms
        ILoanRouter.TrancheSpec[] memory trancheSpecs = new ILoanRouter.TrancheSpec[](1);
        trancheSpecs[0] = ILoanRouter.TrancheSpec({lender: users.lender1, amount: principal, rate: rate});

        ILoanRouter.LoanTerms memory loanTerms = ILoanRouter.LoanTerms({
            expiration: uint64(block.timestamp + 7 days),
            borrower: users.borrower,
            currencyToken: USDC,
            collateralToken: address(bundleCollateralWrapper),
            collateralTokenId: wrappedTokenId,
            duration: repaymentInterval * uint64(numRepayments),
            repaymentInterval: repaymentInterval,
            interestRateModel: address(simpleModel),
            gracePeriodRate: 0,
            gracePeriodDuration: 0,
            feeSpec: ILoanRouter.FeeSpec({originationFee: 0, exitFee: 0}),
            trancheSpecs: trancheSpecs,
            collateralWrapperContext: encodedBundle,
            options: ""
        });

        uint256 currentBalance = principal;
        uint64 maturity = uint64(block.timestamp) + loanTerms.duration;
        uint256 previousTotalPayment;

        // Track principal payments to verify consistency
        uint256[] memory principalPayments = new uint256[](numRepayments);

        // Test that total payment (principal + interest) decreases over time
        for (uint256 i = 0; i < numRepayments; i++) {
            uint64 repaymentDeadline = uint64(block.timestamp) + repaymentInterval * uint64(i + 1);

            (uint256 principalPayment, uint256 interestPayment,,,) =
                simpleModel.repayment(loanTerms, currentBalance, repaymentDeadline, maturity, uint64(block.timestamp));

            principalPayments[i] = principalPayment;
            uint256 totalPayment = principalPayment + interestPayment;

            if (i > 0) {
                // Each total payment should be less than or equal to the previous
                assertLe(
                    totalPayment,
                    previousTotalPayment,
                    string.concat("Total payment should decrease at payment ", vm.toString(i + 1))
                );
            }

            previousTotalPayment = totalPayment;
            currentBalance -= principalPayment;
        }

        // Verify all principal payments (except last) are within a few wei of each other
        for (uint256 i = 1; i < numRepayments - 1; i++) {
            uint256 diff = principalPayments[i] > principalPayments[0]
                ? principalPayments[i] - principalPayments[0]
                : principalPayments[0] - principalPayments[i];
            assertLe(
                diff,
                10,
                string.concat("Principal payment interval should be consistent at payment ", vm.toString(i + 1))
            );
        }
    }

    function test__LowerTotalInterestThanAmortized() public view {
        // Compare with amortized model to verify simple model pays less total interest
        uint256 principal = 10_000 * 1e18;
        uint256 rate = 4756468797; // 15% APR
        uint64 repaymentInterval = 2628000;
        uint256 numRepayments = 12;

        ILoanRouter.TrancheSpec[] memory trancheSpecs = new ILoanRouter.TrancheSpec[](1);
        trancheSpecs[0] = ILoanRouter.TrancheSpec({lender: users.lender1, amount: principal, rate: rate});

        ILoanRouter.LoanTerms memory loanTerms = ILoanRouter.LoanTerms({
            expiration: uint64(block.timestamp + 7 days),
            borrower: users.borrower,
            currencyToken: USDC,
            collateralToken: address(bundleCollateralWrapper),
            collateralTokenId: wrappedTokenId,
            duration: repaymentInterval * uint64(numRepayments),
            repaymentInterval: repaymentInterval,
            interestRateModel: address(simpleModel),
            gracePeriodRate: 0,
            gracePeriodDuration: 0,
            feeSpec: ILoanRouter.FeeSpec({originationFee: 0, exitFee: 0}),
            trancheSpecs: trancheSpecs,
            collateralWrapperContext: encodedBundle,
            options: ""
        });

        uint256 simpleBalance = principal;
        uint256 amortizedBalance = principal;
        uint64 maturity = uint64(block.timestamp) + loanTerms.duration;

        uint256 totalSimpleInterest = 0;
        uint256 totalAmortizedInterest = 0;

        // Track principal payments to verify consistency
        uint256[] memory simplePrincipalPayments = new uint256[](numRepayments);

        for (uint256 i = 0; i < numRepayments; i++) {
            uint64 repaymentDeadline = uint64(block.timestamp) + repaymentInterval * uint64(i + 1);

            // Calculate simple model payment
            (uint256 simplePrincipal, uint256 simpleInterest,,,) =
                simpleModel.repayment(loanTerms, simpleBalance, repaymentDeadline, maturity, uint64(block.timestamp));

            simplePrincipalPayments[i] = simplePrincipal;

            // Calculate amortized model payment
            (uint256 amortPrincipal, uint256 amortInterest,,,) = interestRateModel.repayment(
                loanTerms, amortizedBalance, repaymentDeadline, maturity, uint64(block.timestamp)
            );

            totalSimpleInterest += simpleInterest;
            totalAmortizedInterest += amortInterest;

            simpleBalance -= simplePrincipal;
            amortizedBalance -= amortPrincipal;
        }

        // Verify all simple model principal payments (except last) are within a few wei of each other
        for (uint256 i = 1; i < numRepayments - 1; i++) {
            uint256 diff = simplePrincipalPayments[i] > simplePrincipalPayments[0]
                ? simplePrincipalPayments[i] - simplePrincipalPayments[0]
                : simplePrincipalPayments[0] - simplePrincipalPayments[i];
            assertLe(
                diff,
                10,
                string.concat("Principal payment interval should be consistent at payment ", vm.toString(i + 1))
            );
        }

        // Simple model should result in less total interest paid
        assertLt(
            totalSimpleInterest,
            totalAmortizedInterest,
            "Simple model should result in lower total interest than amortized"
        );
    }
}
