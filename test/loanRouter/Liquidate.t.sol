// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.29;

import {BaseTest} from "../Base.t.sol";
import {ILoanRouter} from "src/interfaces/ILoanRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SimpleInterestRateModel} from "src/rates/SimpleInterestRateModel.sol";
import {IInterestRateModel} from "src/interfaces/IInterestRateModel.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract LoanRouterLiquidateTest is BaseTest {
    SimpleInterestRateModel internal simpleInterestRateModel;

    function setUp() public override {
        super.setUp();
        simpleInterestRateModel = new SimpleInterestRateModel();
    }

    /*------------------------------------------------------------------------*/
    /* Helper Functions */
    /*------------------------------------------------------------------------*/

    function _borrowLoan(
        uint256 principal,
        uint256 numTranches
    ) internal returns (ILoanRouter.LoanTerms memory) {
        uint256 originationFee = principal / 100; // 1%
        uint256 exitFee = principal / 200; // 0.5%

        ILoanRouter.LoanTerms memory loanTerms =
            createLoanTerms(users.borrower, principal, numTranches, originationFee, exitFee);

        // Lenders deposit to DepositTimelock
        bytes32 loanTermsHash = loanRouter.loanTermsHash(loanTerms);

        for (uint256 i = 0; i < numTranches; i++) {
            address lender = loanTerms.trancheSpecs[i].lender;
            vm.startPrank(lender);
            uint256 depositAmount = (loanTerms.trancheSpecs[i].amount * 10016 * 1e12) / 10000;
            depositTimelock.deposit(address(loanRouter), loanTermsHash, USDAI, depositAmount, loanTerms.expiration);
            vm.stopPrank();
        }

        // Borrower borrows funds
        vm.startPrank(users.borrower);

        ILoanRouter.LenderDepositInfo[] memory lenderDepositInfos = createDepositTimelockInfos(numTranches);

        loanRouter.borrow(loanTerms, lenderDepositInfos);

        vm.stopPrank();

        return loanTerms;
    }

    /**
     * @notice Helper function to complete liquidation by simulating the liquidator callback
     * @param loanTerms Loan terms
     * @param proceeds Liquidation proceeds to return
     */
    function _completeLiquidation(
        ILoanRouter.LoanTerms memory loanTerms,
        uint256 proceeds
    ) internal {
        // Fund the liquidator with proceeds (simulating successful auction)
        deal(USDC, ENGLISH_AUCTION_LIQUIDATOR, proceeds);

        // Impersonate the liquidator to call the callback
        vm.startPrank(ENGLISH_AUCTION_LIQUIDATOR);

        // Transfer proceeds to LoanRouter
        if (proceeds > 0) {
            IERC20(USDC).transfer(address(loanRouter), proceeds);
        }

        // Call onCollateralLiquidated callback
        loanRouter.onCollateralLiquidated(abi.encode(loanTerms), proceeds);

        vm.stopPrank();
    }

    /**
     * @notice Make `numPayments` on-time repayments using the loan's own interest rate model.
     */
    function _makePayments(
        ILoanRouter.LoanTerms memory loanTerms,
        uint256 numPayments
    ) internal {
        IInterestRateModel irm = IInterestRateModel(loanTerms.interestRateModel);
        uint256 scaleFactor = 10 ** (18 - IERC20Metadata(loanTerms.currencyToken).decimals());

        for (uint256 i; i < numPayments; i++) {
            (, uint64 maturity, uint64 repaymentDeadline, uint256 balance) =
                loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

            warpToNextRepaymentWindow(repaymentDeadline);

            (uint256 principalPayment, uint256 interestPayment,,,) =
                irm.repayment(loanTerms, balance, repaymentDeadline, maturity, uint64(block.timestamp));

            uint256 scaledTotal = principalPayment + interestPayment;
            uint256 amount = scaledTotal % scaleFactor == 0 ? scaledTotal / scaleFactor : scaledTotal / scaleFactor + 1;

            vm.startPrank(users.borrower);
            loanRouter.repay(loanTerms, amount);
            vm.stopPrank();
        }
    }

    /*------------------------------------------------------------------------*/
    /* Test: liquidate() - Success Cases */
    /*------------------------------------------------------------------------*/

    function test__Liquidate_AfterGracePeriod_SingleTranche() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 1);

        // Get loan state before
        (ILoanRouter.LoanStatus statusBefore,, uint64 repaymentDeadline,) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(uint8(statusBefore), uint8(ILoanRouter.LoanStatus.Active), "Loan should be active");

        // Warp past grace period (repaymentDeadline + gracePeriodDuration + 1)
        vm.warp(repaymentDeadline + GRACE_PERIOD_DURATION + 1);

        // Set proceeds to 120% of principal (simulating profit on liquidation)
        uint256 proceeds = principal * 120 / 100;

        // Call liquidate
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        // Verify loan status is Liquidated (before proceeds callback)
        (ILoanRouter.LoanStatus statusAfter,,,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(uint8(statusAfter), uint8(ILoanRouter.LoanStatus.Liquidated), "Loan should be liquidated");

        // Record lender1 balance before
        uint256 lender1BalanceBefore = IERC20(USDC).balanceOf(users.lender1);

        // Complete liquidation (send proceeds and call callback) - simulates separate transaction
        _completeLiquidation(loanTerms, proceeds);

        // Record lender1 balance after
        uint256 lender1BalanceAfter = IERC20(USDC).balanceOf(users.lender1);

        // Lender1 should receive proceeds
        assertGt(lender1BalanceAfter - lender1BalanceBefore, principal, "Lender1 should receive proceeds");

        // Verify loan status is now CollateralLiquidated
        (statusAfter,,,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(
            uint8(statusAfter),
            uint8(ILoanRouter.LoanStatus.CollateralLiquidated),
            "Loan should be collateral liquidated"
        );
    }

    function test__Liquidate_AfterGracePeriod_MultipleTranches() public {
        uint256 principal = 300_000 * 1e6; // 300k USDC
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 3);

        // Get repayment deadline
        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Warp past grace period
        vm.warp(repaymentDeadline + GRACE_PERIOD_DURATION + 1);

        // Set proceeds to 70% of principal
        uint256 proceeds = (principal * 70) / 100;

        // Record lender balances before
        uint256 lender1BalanceBefore = IERC20(USDC).balanceOf(users.lender1);
        uint256 lender2BalanceBefore = IERC20(USDC).balanceOf(users.lender2);
        uint256 lender3BalanceBefore = IERC20(USDC).balanceOf(users.lender3);
        uint256 feeRecipientBalanceBefore = IERC20(USDC).balanceOf(users.feeRecipient);

        // Call liquidate
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        // Complete liquidation
        _completeLiquidation(loanTerms, proceeds);

        // Verify loan status is CollateralLiquidated (after callback)
        (ILoanRouter.LoanStatus statusAfter,,, uint256 balanceAfter) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(
            uint8(statusAfter),
            uint8(ILoanRouter.LoanStatus.CollateralLiquidated),
            "Loan should be collateral liquidated"
        );
        assertEq(balanceAfter, 0, "Loan balance should be zero");

        // Verify lenders received their share of proceeds
        uint256 lender1BalanceAfter = IERC20(USDC).balanceOf(users.lender1);
        uint256 lender2BalanceAfter = IERC20(USDC).balanceOf(users.lender2);
        uint256 lender3BalanceAfter = IERC20(USDC).balanceOf(users.lender3);
        uint256 feeRecipientBalanceAfter = IERC20(USDC).balanceOf(users.feeRecipient);

        // All lenders should receive something (proceeds distributed)
        assertGt(lender1BalanceAfter, lender1BalanceBefore, "Lender1 should receive proceeds");
        assertGt(lender2BalanceAfter, lender2BalanceBefore, "Lender2 should receive proceeds");

        // Fee recipient should receive liquidation fee
        assertGt(feeRecipientBalanceAfter, feeRecipientBalanceBefore, "Fee recipient should receive liquidation fee");

        // Total distributed should equal proceeds
        assertEq(
            lender1BalanceAfter - lender1BalanceBefore + lender2BalanceAfter - lender2BalanceBefore
                + feeRecipientBalanceAfter - feeRecipientBalanceBefore,
            proceeds,
            "Total distributed should equal proceeds"
        );

        // Lender3 should receive nothing
        assertEq(lender3BalanceAfter, lender3BalanceBefore, "Lender3 should receive nothing");
    }

    /*------------------------------------------------------------------------*/
    /* Test: liquidate() - Failure Cases */
    /*------------------------------------------------------------------------*/

    function test__Liquidate_RevertIf_LoanNotActive() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms =
            createLoanTerms(users.borrower, principal, 1, principal / 100, principal / 200);

        // Try to liquidate before borrowing
        vm.startPrank(users.liquidator);
        vm.expectRevert(ILoanRouter.InvalidLoanState.selector);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();
    }

    function test__Liquidate_RevertIf_WithinGracePeriod() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 1);

        // Get repayment deadline
        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Warp to within grace period (repaymentDeadline + 1 day, still within 30 day grace)
        vm.warp(repaymentDeadline + 1 days);

        // Try to liquidate
        vm.startPrank(users.liquidator);
        vm.expectRevert(ILoanRouter.InvalidLoanState.selector);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();
    }

    function test__Liquidate_RevertIf_BeforeRepaymentDeadline() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 1);

        // Try to liquidate immediately after borrowing (before repayment deadline)
        vm.startPrank(users.liquidator);
        vm.expectRevert(ILoanRouter.InvalidLoanState.selector);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: onCollateralLiquidated() - Success Cases */
    /*------------------------------------------------------------------------*/

    function test__OnCollateralLiquidated_PartialProceeds_DistributesProportionally() public {
        uint256 principal = 300_000 * 1e6; // 300k USDC
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 3);

        // Get repayment deadline
        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Warp past grace period
        vm.warp(repaymentDeadline + GRACE_PERIOD_DURATION + 1);

        // Set proceeds to only 50% of principal (severe loss)
        uint256 proceeds = (principal * 50) / 100;

        // Record balances before
        uint256 lender1BalanceBefore = IERC20(USDC).balanceOf(users.lender1);
        uint256 lender2BalanceBefore = IERC20(USDC).balanceOf(users.lender2);
        uint256 lender3BalanceBefore = IERC20(USDC).balanceOf(users.lender3);

        // Call liquidate
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        // Complete liquidation
        _completeLiquidation(loanTerms, proceeds);

        // Verify lenders received proportional shares
        uint256 lender1BalanceAfter = IERC20(USDC).balanceOf(users.lender1);
        uint256 lender2BalanceAfter = IERC20(USDC).balanceOf(users.lender2);
        uint256 lender3BalanceAfter = IERC20(USDC).balanceOf(users.lender3);

        uint256 lender1Gain = lender1BalanceAfter - lender1BalanceBefore;
        uint256 lender2Gain = lender2BalanceAfter - lender2BalanceBefore;

        // All lender1 and lender2 should receive something
        assertGt(lender1Gain, 0, "Lender1 should receive proceeds");
        assertGt(lender2Gain, 0, "Lender2 should receive proceeds");

        // Lender3 should receive nothing
        assertEq(lender3BalanceAfter, lender3BalanceBefore, "Lender3 should receive nothing");

        // Total distributed should be less than or equal to proceeds after fee
        uint256 liquidationFee = (proceeds * LIQUIDATION_FEE_RATE) / 10000;
        uint256 proceedsAfterFee = proceeds - liquidationFee;
        uint256 totalDistributed = lender1Gain + lender2Gain;
        assertEq(totalDistributed, proceedsAfterFee, "Total distributed should not exceed proceeds after fee");
    }

    function test__OnCollateralLiquidated_ZeroProceeds() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 1);

        // Get repayment deadline
        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Warp past grace period
        vm.warp(repaymentDeadline + GRACE_PERIOD_DURATION + 1);

        // Record balances before
        uint256 lender1BalanceBefore = IERC20(USDC).balanceOf(users.lender1);
        uint256 feeRecipientBalanceBefore = IERC20(USDC).balanceOf(users.feeRecipient);

        // Call liquidate
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        // Complete liquidation with zero proceeds
        _completeLiquidation(loanTerms, 0);

        // Verify lender received nothing (or very little due to rounding)
        uint256 lender1BalanceAfter = IERC20(USDC).balanceOf(users.lender1);
        assertEq(lender1BalanceAfter, lender1BalanceBefore, "Lender should receive nothing with zero proceeds");

        // Verify fee recipient received nothing
        uint256 feeRecipientBalanceAfter = IERC20(USDC).balanceOf(users.feeRecipient);
        assertEq(
            feeRecipientBalanceAfter,
            feeRecipientBalanceBefore,
            "Fee recipient should receive nothing with zero proceeds"
        );

        // Verify loan state is CollateralLiquidated with zero balance
        (ILoanRouter.LoanStatus statusAfter,,, uint256 balanceAfter) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(
            uint8(statusAfter),
            uint8(ILoanRouter.LoanStatus.CollateralLiquidated),
            "Loan should be collateral liquidated"
        );
        assertEq(balanceAfter, 0, "Loan balance should be zero");
    }

    /*------------------------------------------------------------------------*/
    /* Test: onCollateralLiquidated() - Failure Cases */
    /*------------------------------------------------------------------------*/

    function test__OnCollateralLiquidated_RevertIf_NotCalledByLiquidator() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 1);

        // Try to call onCollateralLiquidated directly (not from liquidator)
        vm.startPrank(users.liquidator);
        vm.expectRevert(ILoanRouter.InvalidCaller.selector);
        loanRouter.onCollateralLiquidated(abi.encode(loanTerms), 100_000 * 1e6);
        vm.stopPrank();
    }

    function test__OnCollateralLiquidated_RevertIf_LoanNotLiquidated() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 1);

        // Loan is Active, not Liquidated - try to call callback
        vm.startPrank(ENGLISH_AUCTION_LIQUIDATOR);
        vm.expectRevert(ILoanRouter.InvalidLoanState.selector);
        loanRouter.onCollateralLiquidated(abi.encode(loanTerms), 100_000 * 1e6);
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: Liquidation Fee Distribution */
    /*------------------------------------------------------------------------*/

    function test__Liquidation_LiquidationFeeDistribution() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 1);

        // Get repayment deadline
        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Warp past grace period
        vm.warp(repaymentDeadline + GRACE_PERIOD_DURATION + 1);

        // Set proceeds to 80k USDC
        uint256 proceeds = 80_000 * 1e6;

        // Calculate expected liquidation fee (10%)
        uint256 expectedLiquidationFee = (proceeds * LIQUIDATION_FEE_RATE) / 10000;

        // Record fee recipient balance before
        uint256 feeRecipientBalanceBefore = IERC20(USDC).balanceOf(users.feeRecipient);
        uint256 lender1BalanceBefore = IERC20(USDC).balanceOf(users.lender1);

        // Call liquidate
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        // Complete liquidation
        _completeLiquidation(loanTerms, proceeds);

        // Verify fee recipient received liquidation fee + remaining proceeds
        uint256 feeRecipientBalanceAfter = IERC20(USDC).balanceOf(users.feeRecipient);
        uint256 feeRecipientGain = feeRecipientBalanceAfter - feeRecipientBalanceBefore;

        // Fee recipient should receive at least the liquidation fee
        assertGe(feeRecipientGain, expectedLiquidationFee, "Fee recipient should receive at least liquidation fee");

        // Verify lender received proceeds after fee
        uint256 lender1BalanceAfter = IERC20(USDC).balanceOf(users.lender1);
        uint256 lender1Gain = lender1BalanceAfter - lender1BalanceBefore;

        // Lender + fee recipient should receive approximately all proceeds
        uint256 totalDistributed = lender1Gain + feeRecipientGain;
        assertApproxEqAbs(totalDistributed, proceeds, 2, "Total distributed should approximately equal proceeds");
    }

    /*------------------------------------------------------------------------*/
    /* Test: Edge Cases */
    /*------------------------------------------------------------------------*/

    function test__Liquidate_AtExactGracePeriodEnd() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 1);

        // Get repayment deadline
        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Warp to EXACTLY at the end of grace period
        vm.warp(repaymentDeadline + GRACE_PERIOD_DURATION);

        // Set proceeds
        uint256 proceeds = 80_000 * 1e6;

        // Should revert because we need to be AFTER grace period
        vm.startPrank(users.liquidator);
        vm.expectRevert(ILoanRouter.InvalidLoanState.selector);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        // Warp 1 second past grace period
        vm.warp(repaymentDeadline + GRACE_PERIOD_DURATION + 1);

        // Now it should work
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        // Complete liquidation
        _completeLiquidation(loanTerms, proceeds);

        // Verify loan was liquidated
        (ILoanRouter.LoanStatus status,,,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(
            uint8(status), uint8(ILoanRouter.LoanStatus.CollateralLiquidated), "Loan should be collateral liquidated"
        );
    }

    /*------------------------------------------------------------------------*/
    /* Test: Two-call repayment() — accrued interest only                    */
    /*------------------------------------------------------------------------*/

    uint256 internal constant SCALE_FACTOR = 1e12; // 10^(18-6) for USDC
    uint256 internal constant NUM_INTERVALS = LOAN_DURATION / REPAYMENT_INTERVAL; // 36

    /**
     * @notice Mirrors AmortizedInterestRateModel._powInt() for independent formula verification.
     */
    function _powInt(
        uint256 x,
        uint256 n
    ) internal pure returns (uint256) {
        if (n == 0) return 1e18;
        if (n == 1) return x;
        uint256 result = x;
        for (uint256 i = 1; i < n; i++) {
            result = Math.mulDiv(result, x, 1e18);
        }
        return result;
    }

    /**
     * @notice Compute expected scaled interest, exactly mirroring AmortizedInterestRateModel.repayment().
     * Used to independently verify interest amounts without calling the rate model.
     */
    function _computeExpectedInterest(
        uint256 scaledBalance,
        uint256 blendedRate,
        uint256 repaymentInterval_,
        uint256 pendingIntervals,
        uint256 remainingIntervals,
        uint256 gracePeriodRate_,
        uint256 gracePeriodElapsed_
    ) internal pure returns (uint256 totalInterest) {
        uint256 rb = scaledBalance;
        uint256 ri = remainingIntervals;
        for (uint256 i; i < pendingIntervals; i++) {
            uint256 iPayment = Math.mulDiv(rb * blendedRate, repaymentInterval_, 1e18);
            uint256 pPayment =
                ri == 1 ? rb : Math.mulDiv(iPayment, 1e18, _powInt(1e18 + blendedRate * repaymentInterval_, ri) - 1e18);
            totalInterest += iPayment;
            rb -= pPayment;
            ri--;
        }
        // Grace period interest uses original balance (not remaining), matching rate model exactly
        totalInterest += Math.mulDiv(scaledBalance * gracePeriodRate_, gracePeriodElapsed_, 1e18);
    }

    /**
     * @notice Helper: create and borrow a single-interval loan (duration == repaymentInterval)
     * so that maturity == repaymentDeadline at origination.
     */
    function _borrowSingleIntervalLoan(
        uint256 principal
    ) internal returns (ILoanRouter.LoanTerms memory) {
        ILoanRouter.TrancheSpec[] memory trancheSpecs = new ILoanRouter.TrancheSpec[](1);
        trancheSpecs[0] = ILoanRouter.TrancheSpec({lender: users.lender1, amount: principal, rate: RATE_10_PCT});

        ILoanRouter.LoanTerms memory loanTerms = ILoanRouter.LoanTerms({
            expiration: uint64(block.timestamp + 7 days),
            borrower: users.borrower,
            currencyToken: USDC,
            collateralToken: address(bundleCollateralWrapper),
            collateralTokenId: wrappedTokenId,
            duration: REPAYMENT_INTERVAL, // duration == repaymentInterval → maturity == repaymentDeadline
            repaymentInterval: REPAYMENT_INTERVAL,
            interestRateModel: address(interestRateModel),
            gracePeriodRate: GRACE_PERIOD_RATE,
            gracePeriodDuration: uint256(GRACE_PERIOD_DURATION),
            feeSpec: ILoanRouter.FeeSpec({originationFee: principal / 100, exitFee: principal / 200}),
            trancheSpecs: trancheSpecs,
            collateralWrapperContext: encodedBundle,
            options: ""
        });

        bytes32 loanTermsHash = loanRouter.loanTermsHash(loanTerms);

        vm.startPrank(users.lender1);
        uint256 depositAmount = (principal * 10016 * 1e12) / 10000;
        depositTimelock.deposit(address(loanRouter), loanTermsHash, USDAI, depositAmount, loanTerms.expiration);
        vm.stopPrank();

        vm.startPrank(users.borrower);
        loanRouter.borrow(loanTerms, createDepositTimelockInfos(1));
        vm.stopPrank();

        return loanTerms;
    }

    /**
     * @notice Liquidation at interval 1 of 36 (repaymentDeadline + gracePeriodDuration + 1).
     * Since GRACE_PERIOD_DURATION == REPAYMENT_INTERVAL, pendingIntervals == 2 at the earliest
     * valid liquidation point. Verifies interest is charged for exactly those 2 elapsed intervals
     * plus full grace period, not the remaining 36 unaccrued intervals.
     */
    function test__OnCollateralLiquidated_LiquidationAt_Interval1_SingleTranche() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 1);

        (, uint64 maturity, uint64 repaymentDeadline, uint256 scaledBalance) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Earliest valid liquidation: 1 second past grace period end
        uint64 liqTs = repaymentDeadline + GRACE_PERIOD_DURATION + 1;
        vm.warp(liqTs);

        // pendingIntervals: (GRACE_PERIOD_DURATION + 1) / REPAYMENT_INTERVAL == 1, so min(1+1, 36) = 2
        uint256 delta = liqTs - repaymentDeadline;
        uint256 pendingIntervals = Math.min(delta / REPAYMENT_INTERVAL + 1, NUM_INTERVALS);
        uint256 gracePeriodElapsed = Math.min(delta, GRACE_PERIOD_DURATION);
        assertEq(pendingIntervals, 2, "Earliest liquidation gives 2 pending intervals (grace == interval)");
        assertEq(gracePeriodElapsed, GRACE_PERIOD_DURATION, "Full grace period elapsed");

        // Compute expected interest independently using formula
        uint256 expectedScaledInterest = _computeExpectedInterest(
            scaledBalance,
            RATE_10_PCT,
            REPAYMENT_INTERVAL,
            pendingIntervals,
            NUM_INTERVALS,
            GRACE_PERIOD_RATE,
            gracePeriodElapsed
        );
        // Crosscheck formula against rate model
        (,,, uint256[] memory modelInterests,) =
            interestRateModel.repayment(loanTerms, scaledBalance, repaymentDeadline, maturity, liqTs);
        assertEq(expectedScaledInterest, modelInterests[0], "Formula matches rate model");

        // Old behavior: all 36 intervals
        uint256 oldScaledInterest = _computeExpectedInterest(
            scaledBalance,
            RATE_10_PCT,
            REPAYMENT_INTERVAL,
            NUM_INTERVALS,
            NUM_INTERVALS,
            GRACE_PERIOD_RATE,
            gracePeriodElapsed
        );
        assertLt(expectedScaledInterest, oldScaledInterest, "2 intervals << 36 intervals");

        uint256 proceeds = principal * 2;
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        uint256 lender1Before = IERC20(USDC).balanceOf(users.lender1);
        _completeLiquidation(loanTerms, proceeds);
        uint256 lender1Gain = IERC20(USDC).balanceOf(users.lender1) - lender1Before;

        assertEq(lender1Gain, principal + expectedScaledInterest / SCALE_FACTOR, "Interval 1: exact accrued interest");
    }

    /**
     * @notice Intervals 1–17 paid on time; interval 18 is missed and followed by liquidation.
     * After 17 payments the repaymentDeadline is the 18th deadline (19 intervals remain).
     * Liquidating just after the grace period gives pendingIntervals == 2, so only 2 intervals
     * of interest are charged on the reduced balance.
     */
    function test__OnCollateralLiquidated_LiquidationAt_Interval18_SingleTranche() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 1);

        // Pay intervals 1–17 on time; interval 18 is missed
        _makePayments(loanTerms, 17);

        (, uint64 maturity, uint64 repaymentDeadline, uint256 scaledBalance) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Liquidate just after the grace period of the missed 18th payment
        uint64 liqTs = repaymentDeadline + GRACE_PERIOD_DURATION + 1;
        vm.warp(liqTs);

        // 19 intervals remain; delta == GRACE_PERIOD_DURATION + 1 → pendingIntervals == min(2, 19) == 2
        uint256 delta = liqTs - repaymentDeadline;
        uint256 remainingIntervals = (maturity - repaymentDeadline) / REPAYMENT_INTERVAL + 1; // 19
        uint256 pendingIntervals = Math.min(delta / REPAYMENT_INTERVAL + 1, remainingIntervals);
        uint256 gracePeriodElapsed = Math.min(delta, GRACE_PERIOD_DURATION);
        assertEq(pendingIntervals, 2, "Missed 18th payment: 2 pending intervals (grace == interval)");
        assertEq(gracePeriodElapsed, GRACE_PERIOD_DURATION, "Full grace period elapsed");

        uint256 expectedScaledInterest = _computeExpectedInterest(
            scaledBalance,
            RATE_10_PCT,
            REPAYMENT_INTERVAL,
            pendingIntervals,
            remainingIntervals,
            GRACE_PERIOD_RATE,
            gracePeriodElapsed
        );
        (,,, uint256[] memory modelInterests,) =
            interestRateModel.repayment(loanTerms, scaledBalance, repaymentDeadline, maturity, liqTs);
        assertEq(expectedScaledInterest, modelInterests[0], "Formula matches rate model at interval 18");

        // Charging all 19 remaining intervals would give more interest
        uint256 oldScaledInterest = _computeExpectedInterest(
            scaledBalance,
            RATE_10_PCT,
            REPAYMENT_INTERVAL,
            remainingIntervals,
            remainingIntervals,
            GRACE_PERIOD_RATE,
            gracePeriodElapsed
        );
        assertLt(expectedScaledInterest, oldScaledInterest, "2 intervals < 19 remaining intervals");

        uint256 proceeds = principal * 2;
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        uint256 lender1Before = IERC20(USDC).balanceOf(users.lender1);
        _completeLiquidation(loanTerms, proceeds);
        uint256 lender1Gain = IERC20(USDC).balanceOf(users.lender1) - lender1Before;

        assertEq(
            lender1Gain,
            scaledBalance / SCALE_FACTOR + expectedScaledInterest / SCALE_FACTOR,
            "Interval 18: remaining principal + accrued interest"
        );
    }

    /**
     * @notice Intervals 1–35 paid on time; final interval 36 (at maturity) is missed.
     * After 35 payments repaymentDeadline == maturity, so remainingIntervals == 1.
     * Liquidating 1 month after maturity gives pendingIntervals == min(2, 1) == 1 on the
     * reduced final balance.
     */
    function test__OnCollateralLiquidated_LiquidationAt_1MonthAfterMaturity_SingleTranche() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 1);

        // Pay intervals 1–35 on time; final interval 36 is missed
        _makePayments(loanTerms, 35);

        (, uint64 maturity, uint64 repaymentDeadline, uint256 scaledBalance) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // After 35 payments the repaymentDeadline has advanced to maturity (the 36th deadline)
        assertEq(repaymentDeadline, maturity, "Sanity: repaymentDeadline == maturity after 35 payments");

        // Liquidate 1 second past the grace period of the missed final payment
        uint64 liqTs = maturity + GRACE_PERIOD_DURATION + 1;
        vm.warp(liqTs);

        // remainingIntervals == 1; delta == GRACE_PERIOD_DURATION + 1 → pendingIntervals == min(2, 1) == 1
        uint256 delta = liqTs - repaymentDeadline;
        uint256 remainingIntervals = (maturity - repaymentDeadline) / REPAYMENT_INTERVAL + 1; // 1
        uint256 pendingIntervals = Math.min(delta / REPAYMENT_INTERVAL + 1, remainingIntervals);
        uint256 gracePeriodElapsed = Math.min(delta, GRACE_PERIOD_DURATION);
        assertEq(pendingIntervals, 1, "Only 1 remaining interval at maturity");
        assertEq(gracePeriodElapsed, GRACE_PERIOD_DURATION, "Full grace period elapsed");

        // pendingIntervals == remainingIntervals == 1: both calls give identical interest
        uint256 expectedScaledInterest = _computeExpectedInterest(
            scaledBalance,
            RATE_10_PCT,
            REPAYMENT_INTERVAL,
            pendingIntervals,
            remainingIntervals,
            GRACE_PERIOD_RATE,
            gracePeriodElapsed
        );
        (,,, uint256[] memory modelInterests,) =
            interestRateModel.repayment(loanTerms, scaledBalance, repaymentDeadline, maturity, liqTs);
        assertEq(expectedScaledInterest, modelInterests[0], "Formula matches rate model past maturity");

        uint256 oldScaledInterest = _computeExpectedInterest(
            scaledBalance,
            RATE_10_PCT,
            REPAYMENT_INTERVAL,
            remainingIntervals,
            remainingIntervals,
            GRACE_PERIOD_RATE,
            gracePeriodElapsed
        );
        assertEq(expectedScaledInterest, oldScaledInterest, "Past maturity: accrued == all-remaining interest");

        uint256 proceeds = principal * 2;
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        uint256 lender1Before = IERC20(USDC).balanceOf(users.lender1);
        _completeLiquidation(loanTerms, proceeds);
        uint256 lender1Gain = IERC20(USDC).balanceOf(users.lender1) - lender1Before;

        assertEq(
            lender1Gain,
            scaledBalance / SCALE_FACTOR + expectedScaledInterest / SCALE_FACTOR,
            "Past maturity: remaining principal + final interval interest"
        );
    }

    /**
     * @notice Multi-interval loan with multiple tranches: each tranche receives only its
     * proportional share of the accrued interest, verified against independent formula.
     */
    function test__OnCollateralLiquidated_MultiInterval_OnlyAccruedInterest_MultipleTranches() public {
        uint256 principal = 300_000 * 1e6; // 300k USDC, 3 tranches, 36-interval loan
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 3);

        (, uint64 maturity, uint64 repaymentDeadline, uint256 scaledBalance) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        uint64 liqTs = repaymentDeadline + GRACE_PERIOD_DURATION + 1;
        vm.warp(liqTs);

        uint256 delta = liqTs - repaymentDeadline;
        uint256 pendingIntervals = Math.min(delta / REPAYMENT_INTERVAL + 1, NUM_INTERVALS);
        uint256 gracePeriodElapsed = Math.min(delta, GRACE_PERIOD_DURATION);

        // Blended rate for 3 equal tranches at 8%, 10%, 14%
        uint256 blendedRate = (RATE_8_PCT + RATE_10_PCT + RATE_14_PCT) / 3;
        uint256 totalWeightedRate = (RATE_8_PCT + RATE_10_PCT + RATE_14_PCT) * (principal / 3);

        uint256 expectedScaledInterestTotal = _computeExpectedInterest(
            scaledBalance,
            blendedRate,
            REPAYMENT_INTERVAL,
            pendingIntervals,
            NUM_INTERVALS,
            GRACE_PERIOD_RATE,
            gracePeriodElapsed
        );
        // Crosscheck total against rate model
        (,,, uint256[] memory modelInterests,) =
            interestRateModel.repayment(loanTerms, scaledBalance, repaymentDeadline, maturity, liqTs);
        uint256 modelInterestTotal = modelInterests[0] + modelInterests[1] + modelInterests[2];
        assertEq(expectedScaledInterestTotal, modelInterestTotal, "Formula matches rate model total");

        // Old behavior (all 36 intervals) for comparison
        uint256 oldScaledInterestTotal = _computeExpectedInterest(
            scaledBalance,
            blendedRate,
            REPAYMENT_INTERVAL,
            NUM_INTERVALS,
            NUM_INTERVALS,
            GRACE_PERIOD_RATE,
            gracePeriodElapsed
        );
        assertLt(expectedScaledInterestTotal, oldScaledInterestTotal, "Accrued total < all-interval total");

        uint256 proceeds = principal * 2;
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        uint256[3] memory beforeBalances = [
            IERC20(USDC).balanceOf(users.lender1),
            IERC20(USDC).balanceOf(users.lender2),
            IERC20(USDC).balanceOf(users.lender3)
        ];
        _completeLiquidation(loanTerms, proceeds);

        // Total lender gain matches expected principal + accrued interest exactly
        uint256[3] memory rates = [RATE_8_PCT, RATE_10_PCT, RATE_14_PCT];
        uint256 perTranche = principal / 3;
        uint256 totalGain;
        address payable[3] memory lenders = [users.lender1, users.lender2, users.lender3];
        for (uint256 i = 0; i < 3; i++) {
            uint256 gain = IERC20(USDC).balanceOf(lenders[i]) - beforeBalances[i];
            totalGain += gain;

            // Per-tranche interest: totalInterest * rate_i * amount_i / totalWeightedRate
            uint256 expTrancheInterest =
                Math.mulDiv(expectedScaledInterestTotal, rates[i] * perTranche, totalWeightedRate);
            // Dust from rate model rounding goes to tranche 0; allow tolerance of 1
            assertApproxEqAbs(
                gain, perTranche + expTrancheInterest / SCALE_FACTOR, 1, "Each tranche: accrued interest only"
            );
        }
        assertEq(totalGain, principal + expectedScaledInterestTotal / SCALE_FACTOR, "Total: full principal + accrued");
    }

    /**
     * @notice Single-interval loan (maturity == repaymentDeadline): block.timestamp call
     * correctly captures grace period interest. With timestamp=maturity, gracePeriodElapsed
     * = min(maturity - repaymentDeadline, gracePeriodDuration) = 0, so grace is missing.
     */
    function test__OnCollateralLiquidated_SingleInterval_GracePeriodInterestIncluded() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowSingleIntervalLoan(principal);

        (, uint64 maturity, uint64 repaymentDeadline, uint256 scaledBalance) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        assertEq(maturity, repaymentDeadline, "maturity must equal repaymentDeadline for single-interval loan");

        uint64 liqTs = repaymentDeadline + GRACE_PERIOD_DURATION + 1;
        vm.warp(liqTs);

        uint256 delta = liqTs - repaymentDeadline;

        // With block.timestamp: 1 interval + full grace period
        uint256 expectedScaledInterest = _computeExpectedInterest(
            scaledBalance,
            RATE_10_PCT,
            REPAYMENT_INTERVAL,
            1, // pendingIntervals (single-interval: remainingIntervals == 1)
            1, // remainingIntervals
            GRACE_PERIOD_RATE,
            Math.min(delta, GRACE_PERIOD_DURATION)
        );
        // Without grace (using maturity as timestamp): min(0, gracePeriodDuration) = 0 grace
        uint256 noGraceScaledInterest = _computeExpectedInterest(
            scaledBalance,
            RATE_10_PCT,
            REPAYMENT_INTERVAL,
            1,
            1,
            GRACE_PERIOD_RATE,
            0 // gracePeriodElapsed = min(maturity - repaymentDeadline, ...) = 0
        );

        // Crosscheck both against rate model
        (,,, uint256[] memory withGrace,) =
            interestRateModel.repayment(loanTerms, scaledBalance, repaymentDeadline, maturity, liqTs);
        (,,, uint256[] memory withoutGrace,) =
            interestRateModel.repayment(loanTerms, scaledBalance, repaymentDeadline, maturity, maturity);
        assertEq(expectedScaledInterest, withGrace[0], "Formula matches model (with grace)");
        assertEq(noGraceScaledInterest, withoutGrace[0], "Formula matches model (without grace)");

        assertGt(expectedScaledInterest, noGraceScaledInterest, "block.timestamp adds grace period interest");

        // Grace period component = scaledBalance * GRACE_PERIOD_RATE * gracePeriodDuration / 1e18
        uint256 graceComponent = Math.mulDiv(scaledBalance * GRACE_PERIOD_RATE, GRACE_PERIOD_DURATION, 1e18);
        assertEq(expectedScaledInterest - noGraceScaledInterest, graceComponent, "Grace delta matches formula");

        uint256 proceeds = principal * 2;
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        uint256 lender1Before = IERC20(USDC).balanceOf(users.lender1);
        _completeLiquidation(loanTerms, proceeds);
        uint256 lender1Gain = IERC20(USDC).balanceOf(users.lender1) - lender1Before;

        assertEq(
            lender1Gain,
            principal + expectedScaledInterest / SCALE_FACTOR,
            "Single-interval: full principal + interval + grace interest"
        );
    }

    /*------------------------------------------------------------------------*/
    /* Test: Two-call repayment() — SimpleInterestRateModel                 */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Borrow a multi-interval loan using a custom interest rate model.
     */
    function _borrowLoanWith(
        uint256 principal,
        uint256 numTranches,
        address rateModel
    ) internal returns (ILoanRouter.LoanTerms memory) {
        uint256 originationFee = principal / 100;
        uint256 exitFee = principal / 200;

        ILoanRouter.LoanTerms memory loanTerms =
            createLoanTerms(users.borrower, principal, numTranches, originationFee, exitFee, rateModel);

        bytes32 loanTermsHash = loanRouter.loanTermsHash(loanTerms);

        for (uint256 i = 0; i < numTranches; i++) {
            address lender = loanTerms.trancheSpecs[i].lender;
            vm.startPrank(lender);
            uint256 depositAmount = (loanTerms.trancheSpecs[i].amount * 10016 * 1e12) / 10000;
            depositTimelock.deposit(address(loanRouter), loanTermsHash, USDAI, depositAmount, loanTerms.expiration);
            vm.stopPrank();
        }

        vm.startPrank(users.borrower);
        loanRouter.borrow(loanTerms, createDepositTimelockInfos(numTranches));
        vm.stopPrank();

        return loanTerms;
    }

    /**
     * @notice Borrow a single-interval loan using a custom interest rate model.
     */
    function _borrowSingleIntervalLoanWith(
        uint256 principal,
        address rateModel
    ) internal returns (ILoanRouter.LoanTerms memory) {
        ILoanRouter.TrancheSpec[] memory trancheSpecs = new ILoanRouter.TrancheSpec[](1);
        trancheSpecs[0] = ILoanRouter.TrancheSpec({lender: users.lender1, amount: principal, rate: RATE_10_PCT});

        ILoanRouter.LoanTerms memory loanTerms = ILoanRouter.LoanTerms({
            expiration: uint64(block.timestamp + 7 days),
            borrower: users.borrower,
            currencyToken: USDC,
            collateralToken: address(bundleCollateralWrapper),
            collateralTokenId: wrappedTokenId,
            duration: REPAYMENT_INTERVAL,
            repaymentInterval: REPAYMENT_INTERVAL,
            interestRateModel: rateModel,
            gracePeriodRate: GRACE_PERIOD_RATE,
            gracePeriodDuration: uint256(GRACE_PERIOD_DURATION),
            feeSpec: ILoanRouter.FeeSpec({originationFee: principal / 100, exitFee: principal / 200}),
            trancheSpecs: trancheSpecs,
            collateralWrapperContext: encodedBundle,
            options: ""
        });

        bytes32 loanTermsHash = loanRouter.loanTermsHash(loanTerms);

        vm.startPrank(users.lender1);
        uint256 depositAmount = (principal * 10016 * 1e12) / 10000;
        depositTimelock.deposit(address(loanRouter), loanTermsHash, USDAI, depositAmount, loanTerms.expiration);
        vm.stopPrank();

        vm.startPrank(users.borrower);
        loanRouter.borrow(loanTerms, createDepositTimelockInfos(1));
        vm.stopPrank();

        return loanTerms;
    }

    /**
     * @notice Compute expected interest using SimpleInterestRateModel's formula.
     * principalPayment is constant (= scaledBalance / remainingIntervals); each iteration
     * charges interest on the declining balance then deducts that constant principal slice.
     */
    function _computeExpectedInterestSimple(
        uint256 scaledBalance,
        uint256 blendedRate,
        uint256 repaymentInterval_,
        uint256 pendingIntervals,
        uint256 remainingIntervals,
        uint256 gracePeriodRate_,
        uint256 gracePeriodElapsed_
    ) internal pure returns (uint256 totalInterest) {
        uint256 rb = scaledBalance;
        uint256 principalPayment = scaledBalance / remainingIntervals;
        for (uint256 i; i < pendingIntervals; i++) {
            totalInterest += Math.mulDiv(rb * blendedRate, repaymentInterval_, 1e18);
            rb -= principalPayment;
        }
        totalInterest += Math.mulDiv(scaledBalance * gracePeriodRate_, gracePeriodElapsed_, 1e18);
    }

    /**
     * @notice SimpleIRM — liquidation at interval 1 of 36.
     */
    function test__OnCollateralLiquidated_LiquidationAt_Interval1_SingleTranche_SimpleIRM() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoanWith(principal, 1, address(simpleInterestRateModel));

        (, uint64 maturity, uint64 repaymentDeadline, uint256 scaledBalance) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        uint64 liqTs = repaymentDeadline + GRACE_PERIOD_DURATION + 1;
        vm.warp(liqTs);

        uint256 delta = liqTs - repaymentDeadline;
        uint256 pendingIntervals = Math.min(delta / REPAYMENT_INTERVAL + 1, NUM_INTERVALS);
        uint256 gracePeriodElapsed = Math.min(delta, GRACE_PERIOD_DURATION);
        assertEq(pendingIntervals, 2, "Earliest liquidation gives 2 pending intervals (grace == interval)");
        assertEq(gracePeriodElapsed, GRACE_PERIOD_DURATION, "Full grace period elapsed");

        uint256 expectedScaledInterest = _computeExpectedInterestSimple(
            scaledBalance,
            RATE_10_PCT,
            REPAYMENT_INTERVAL,
            pendingIntervals,
            NUM_INTERVALS,
            GRACE_PERIOD_RATE,
            gracePeriodElapsed
        );
        (,,, uint256[] memory modelInterests,) =
            simpleInterestRateModel.repayment(loanTerms, scaledBalance, repaymentDeadline, maturity, liqTs);
        assertEq(expectedScaledInterest, modelInterests[0], "Formula matches Simple IRM at interval 1");

        uint256 oldScaledInterest = _computeExpectedInterestSimple(
            scaledBalance,
            RATE_10_PCT,
            REPAYMENT_INTERVAL,
            NUM_INTERVALS,
            NUM_INTERVALS,
            GRACE_PERIOD_RATE,
            gracePeriodElapsed
        );
        assertLt(expectedScaledInterest, oldScaledInterest, "2 intervals << 36 intervals");

        uint256 proceeds = principal * 2;
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        uint256 lender1Before = IERC20(USDC).balanceOf(users.lender1);
        _completeLiquidation(loanTerms, proceeds);
        uint256 lender1Gain = IERC20(USDC).balanceOf(users.lender1) - lender1Before;

        assertEq(lender1Gain, principal + expectedScaledInterest / SCALE_FACTOR, "Interval 1: exact accrued interest");
    }

    /**
     * @notice SimpleIRM — liquidation at interval 18 of 36.
     */
    function test__OnCollateralLiquidated_LiquidationAt_Interval18_SingleTranche_SimpleIRM() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoanWith(principal, 1, address(simpleInterestRateModel));

        // Pay intervals 1–17 on time; interval 18 is missed
        _makePayments(loanTerms, 17);

        (, uint64 maturity, uint64 repaymentDeadline, uint256 scaledBalance) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Liquidate just after the grace period of the missed 18th payment
        uint64 liqTs = repaymentDeadline + GRACE_PERIOD_DURATION + 1;
        vm.warp(liqTs);

        // 19 intervals remain; delta == GRACE_PERIOD_DURATION + 1 → pendingIntervals == min(2, 19) == 2
        uint256 delta = liqTs - repaymentDeadline;
        uint256 remainingIntervals = (maturity - repaymentDeadline) / REPAYMENT_INTERVAL + 1; // 19
        uint256 pendingIntervals = Math.min(delta / REPAYMENT_INTERVAL + 1, remainingIntervals);
        uint256 gracePeriodElapsed = Math.min(delta, GRACE_PERIOD_DURATION);
        assertEq(pendingIntervals, 2, "Missed 18th payment: 2 pending intervals (grace == interval)");
        assertEq(gracePeriodElapsed, GRACE_PERIOD_DURATION, "Full grace period elapsed");

        uint256 expectedScaledInterest = _computeExpectedInterestSimple(
            scaledBalance,
            RATE_10_PCT,
            REPAYMENT_INTERVAL,
            pendingIntervals,
            remainingIntervals,
            GRACE_PERIOD_RATE,
            gracePeriodElapsed
        );
        (,,, uint256[] memory modelInterests,) =
            simpleInterestRateModel.repayment(loanTerms, scaledBalance, repaymentDeadline, maturity, liqTs);
        assertEq(expectedScaledInterest, modelInterests[0], "Formula matches Simple IRM at interval 18");

        // Charging all 19 remaining intervals would give more interest
        uint256 oldScaledInterest = _computeExpectedInterestSimple(
            scaledBalance,
            RATE_10_PCT,
            REPAYMENT_INTERVAL,
            remainingIntervals,
            remainingIntervals,
            GRACE_PERIOD_RATE,
            gracePeriodElapsed
        );
        assertLt(expectedScaledInterest, oldScaledInterest, "2 intervals < 19 remaining intervals");

        uint256 proceeds = principal * 2;
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        uint256 lender1Before = IERC20(USDC).balanceOf(users.lender1);
        _completeLiquidation(loanTerms, proceeds);
        uint256 lender1Gain = IERC20(USDC).balanceOf(users.lender1) - lender1Before;

        assertEq(
            lender1Gain,
            scaledBalance / SCALE_FACTOR + expectedScaledInterest / SCALE_FACTOR,
            "Interval 18: remaining principal + accrued interest"
        );
    }

    /**
     * @notice SimpleIRM — intervals 1–35 paid on time; final interval 36 missed, liquidated 1 month after maturity.
     */
    function test__OnCollateralLiquidated_LiquidationAt_1MonthAfterMaturity_SingleTranche_SimpleIRM() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoanWith(principal, 1, address(simpleInterestRateModel));

        // Pay intervals 1–35 on time; final interval 36 is missed
        _makePayments(loanTerms, 35);

        (, uint64 maturity, uint64 repaymentDeadline, uint256 scaledBalance) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // After 35 payments the repaymentDeadline has advanced to maturity (the 36th deadline)
        assertEq(repaymentDeadline, maturity, "Sanity: repaymentDeadline == maturity after 35 payments");

        // Liquidate 1 second past the grace period of the missed final payment
        uint64 liqTs = maturity + GRACE_PERIOD_DURATION + 1;
        vm.warp(liqTs);

        // remainingIntervals == 1; delta == GRACE_PERIOD_DURATION + 1 → pendingIntervals == min(2, 1) == 1
        uint256 delta = liqTs - repaymentDeadline;
        uint256 remainingIntervals = (maturity - repaymentDeadline) / REPAYMENT_INTERVAL + 1; // 1
        uint256 pendingIntervals = Math.min(delta / REPAYMENT_INTERVAL + 1, remainingIntervals);
        uint256 gracePeriodElapsed = Math.min(delta, GRACE_PERIOD_DURATION);
        assertEq(pendingIntervals, 1, "Only 1 remaining interval at maturity");
        assertEq(gracePeriodElapsed, GRACE_PERIOD_DURATION, "Full grace period elapsed");

        // pendingIntervals == remainingIntervals == 1: both calls give identical interest
        uint256 expectedScaledInterest = _computeExpectedInterestSimple(
            scaledBalance,
            RATE_10_PCT,
            REPAYMENT_INTERVAL,
            pendingIntervals,
            remainingIntervals,
            GRACE_PERIOD_RATE,
            gracePeriodElapsed
        );
        (,,, uint256[] memory modelInterests,) =
            simpleInterestRateModel.repayment(loanTerms, scaledBalance, repaymentDeadline, maturity, liqTs);
        assertEq(expectedScaledInterest, modelInterests[0], "Formula matches Simple IRM past maturity");

        uint256 oldScaledInterest = _computeExpectedInterestSimple(
            scaledBalance,
            RATE_10_PCT,
            REPAYMENT_INTERVAL,
            remainingIntervals,
            remainingIntervals,
            GRACE_PERIOD_RATE,
            gracePeriodElapsed
        );
        assertEq(expectedScaledInterest, oldScaledInterest, "Past maturity: accrued == all-remaining interest");

        uint256 proceeds = principal * 2;
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        uint256 lender1Before = IERC20(USDC).balanceOf(users.lender1);
        _completeLiquidation(loanTerms, proceeds);
        uint256 lender1Gain = IERC20(USDC).balanceOf(users.lender1) - lender1Before;

        assertEq(
            lender1Gain,
            scaledBalance / SCALE_FACTOR + expectedScaledInterest / SCALE_FACTOR,
            "Past maturity: remaining principal + final interval interest"
        );
    }

    /**
     * @notice SimpleIRM — multiple tranches; each tranche receives only its proportional
     * share of accrued interest.
     */
    function test__OnCollateralLiquidated_MultiInterval_OnlyAccruedInterest_MultipleTranches_SimpleIRM() public {
        uint256 principal = 300_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoanWith(principal, 3, address(simpleInterestRateModel));

        (, uint64 maturity, uint64 repaymentDeadline, uint256 scaledBalance) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        uint64 liqTs = repaymentDeadline + GRACE_PERIOD_DURATION + 1;
        vm.warp(liqTs);

        uint256 delta = liqTs - repaymentDeadline;
        uint256 pendingIntervals = Math.min(delta / REPAYMENT_INTERVAL + 1, NUM_INTERVALS);
        uint256 gracePeriodElapsed = Math.min(delta, GRACE_PERIOD_DURATION);

        uint256 blendedRate = (RATE_8_PCT + RATE_10_PCT + RATE_14_PCT) / 3;
        uint256 totalWeightedRate = (RATE_8_PCT + RATE_10_PCT + RATE_14_PCT) * (principal / 3);

        uint256 expectedScaledInterestTotal = _computeExpectedInterestSimple(
            scaledBalance,
            blendedRate,
            REPAYMENT_INTERVAL,
            pendingIntervals,
            NUM_INTERVALS,
            GRACE_PERIOD_RATE,
            gracePeriodElapsed
        );
        (,,, uint256[] memory modelInterests,) =
            simpleInterestRateModel.repayment(loanTerms, scaledBalance, repaymentDeadline, maturity, liqTs);
        uint256 modelInterestTotal = modelInterests[0] + modelInterests[1] + modelInterests[2];
        assertEq(expectedScaledInterestTotal, modelInterestTotal, "Formula matches Simple IRM total");

        uint256 oldScaledInterestTotal = _computeExpectedInterestSimple(
            scaledBalance,
            blendedRate,
            REPAYMENT_INTERVAL,
            NUM_INTERVALS,
            NUM_INTERVALS,
            GRACE_PERIOD_RATE,
            gracePeriodElapsed
        );
        assertLt(expectedScaledInterestTotal, oldScaledInterestTotal, "Accrued total < all-interval total");

        uint256 proceeds = principal * 2;
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        uint256[3] memory beforeBalances = [
            IERC20(USDC).balanceOf(users.lender1),
            IERC20(USDC).balanceOf(users.lender2),
            IERC20(USDC).balanceOf(users.lender3)
        ];
        _completeLiquidation(loanTerms, proceeds);

        uint256[3] memory rates = [RATE_8_PCT, RATE_10_PCT, RATE_14_PCT];
        uint256 perTranche = principal / 3;
        uint256 totalGain;
        address payable[3] memory lenders = [users.lender1, users.lender2, users.lender3];
        for (uint256 i = 0; i < 3; i++) {
            uint256 gain = IERC20(USDC).balanceOf(lenders[i]) - beforeBalances[i];
            totalGain += gain;

            uint256 expTrancheInterest =
                Math.mulDiv(expectedScaledInterestTotal, rates[i] * perTranche, totalWeightedRate);
            assertApproxEqAbs(
                gain, perTranche + expTrancheInterest / SCALE_FACTOR, 1, "Each tranche: accrued interest only"
            );
        }
        assertApproxEqAbs(
            totalGain, principal + expectedScaledInterestTotal / SCALE_FACTOR, 1, "Total: full principal + accrued"
        );
    }

    /**
     * @notice SimpleIRM — single-interval loan: block.timestamp call captures grace period interest.
     */
    function test__OnCollateralLiquidated_SingleInterval_GracePeriodInterestIncluded_SimpleIRM() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms =
            _borrowSingleIntervalLoanWith(principal, address(simpleInterestRateModel));

        (, uint64 maturity, uint64 repaymentDeadline, uint256 scaledBalance) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        assertEq(maturity, repaymentDeadline, "maturity must equal repaymentDeadline for single-interval loan");

        uint64 liqTs = repaymentDeadline + GRACE_PERIOD_DURATION + 1;
        vm.warp(liqTs);

        uint256 delta = liqTs - repaymentDeadline;

        uint256 expectedScaledInterest = _computeExpectedInterestSimple(
            scaledBalance,
            RATE_10_PCT,
            REPAYMENT_INTERVAL,
            1,
            1,
            GRACE_PERIOD_RATE,
            Math.min(delta, GRACE_PERIOD_DURATION)
        );
        uint256 noGraceScaledInterest =
            _computeExpectedInterestSimple(scaledBalance, RATE_10_PCT, REPAYMENT_INTERVAL, 1, 1, GRACE_PERIOD_RATE, 0);

        (,,, uint256[] memory withGrace,) =
            simpleInterestRateModel.repayment(loanTerms, scaledBalance, repaymentDeadline, maturity, liqTs);
        (,,, uint256[] memory withoutGrace,) =
            simpleInterestRateModel.repayment(loanTerms, scaledBalance, repaymentDeadline, maturity, maturity);
        assertEq(expectedScaledInterest, withGrace[0], "Formula matches Simple IRM (with grace)");
        assertEq(noGraceScaledInterest, withoutGrace[0], "Formula matches Simple IRM (without grace)");

        assertGt(expectedScaledInterest, noGraceScaledInterest, "block.timestamp adds grace period interest");

        uint256 graceComponent = Math.mulDiv(scaledBalance * GRACE_PERIOD_RATE, GRACE_PERIOD_DURATION, 1e18);
        assertEq(expectedScaledInterest - noGraceScaledInterest, graceComponent, "Grace delta matches formula");

        uint256 proceeds = principal * 2;
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        uint256 lender1Before = IERC20(USDC).balanceOf(users.lender1);
        _completeLiquidation(loanTerms, proceeds);
        uint256 lender1Gain = IERC20(USDC).balanceOf(users.lender1) - lender1Before;

        assertEq(
            lender1Gain,
            principal + expectedScaledInterest / SCALE_FACTOR,
            "Single-interval: full principal + interval + grace interest"
        );
    }

    function test__Liquidate_VerySmallProceeds() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 3);

        // Get repayment deadline
        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Warp past grace period
        vm.warp(repaymentDeadline + GRACE_PERIOD_DURATION + 1);

        // Set very small proceeds (1 USDC)
        uint256 proceeds = 1 * 1e6;

        // Call liquidate
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        // Complete liquidation
        _completeLiquidation(loanTerms, proceeds);

        // Verify loan was liquidated successfully despite tiny proceeds
        (ILoanRouter.LoanStatus status,,, uint256 balance) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(
            uint8(status), uint8(ILoanRouter.LoanStatus.CollateralLiquidated), "Loan should be collateral liquidated"
        );
        assertEq(balance, 0, "Loan balance should be zero");
    }
}
