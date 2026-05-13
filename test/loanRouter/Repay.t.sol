// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

import {BaseTest} from "../Base.t.sol";
import {ILoanRouter} from "src/interfaces/ILoanRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract LoanRouterRepayTest is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Helper: Setup loan */
    /*------------------------------------------------------------------------*/

    function setupLoan(
        uint256 principal,
        uint256 numTranches
    ) internal returns (ILoanRouter.LoanTerms memory loanTerms, bytes32 loanTermsHash) {
        uint256 originationFee = principal / 100; // 1% origination fee
        uint256 exitFee = principal / 200; // 0.5% exit fee

        loanTerms = createLoanTerms(users.borrower, principal, numTranches, originationFee, exitFee);
        loanTermsHash = loanRouter.loanTermsHash(loanTerms);

        // Setup deposits for all tranches
        address[] memory lenders = new address[](3);
        lenders[0] = users.lender1;
        lenders[1] = users.lender2;
        lenders[2] = users.lender3;

        for (uint256 i = 0; i < numTranches; i++) {
            vm.startPrank(lenders[i]);
            // Apply 1.6bps slippage and convert to USDai decimals
            uint256 depositAmount = (loanTerms.trancheSpecs[i].amount * 10016 * 1e12) / 10000;
            depositTimelock.deposit(address(loanRouter), loanTermsHash, USDAI, depositAmount, loanTerms.expiration);
            vm.stopPrank();
        }

        // Borrow
        vm.startPrank(users.borrower);

        ILoanRouter.LenderDepositInfo[] memory lenderDepositInfos = createDepositTimelockInfos(numTranches);

        loanRouter.borrow(loanTerms, lenderDepositInfos);
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: On-time repayment (single interval) */
    /*------------------------------------------------------------------------*/

    function test__Repay_OnTime_SingleInterval_SingleTranche() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 1);

        // Get loan state
        (,, uint64 repaymentDeadline, uint256 balance) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Warp to repayment window (just after repayment window opens)
        warpToNextRepaymentWindow(repaymentDeadline);

        // Record balances
        uint256 borrowerUsdcBefore = IERC20(USDC).balanceOf(users.borrower);
        uint256 lender1UsdcBefore = IERC20(USDC).balanceOf(users.lender1);

        // Repay
        vm.startPrank(users.borrower);
        uint256 requiredPayment = calculateRequiredRepayment(loanTerms);
        loanRouter.repay(loanTerms, requiredPayment); // Pay required amount, no prepayment
        vm.stopPrank();

        // Verify loan state updated
        (,, uint64 newRepaymentDeadline, uint256 newBalance) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Balance should be reduced
        assertLt(newBalance, balance, "Balance should be reduced");

        // Repayment deadline should be advanced
        assertEq(newRepaymentDeadline, repaymentDeadline + REPAYMENT_INTERVAL, "Repayment deadline should advance");

        // Verify borrower paid
        assertLt(IERC20(USDC).balanceOf(users.borrower), borrowerUsdcBefore, "Borrower should have paid");

        // Verify lender received payment
        assertGt(IERC20(USDC).balanceOf(users.lender1), lender1UsdcBefore, "Lender should have received payment");
    }

    function test__Repay_OnTime_MultipleTranches() public {
        uint256 principal = 300_000 * 1e6; // 300k USDC

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 3);

        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Warp to repayment window
        warpToNextRepaymentWindow(repaymentDeadline);

        // Record balances
        uint256 lender1Before = IERC20(USDC).balanceOf(users.lender1);
        uint256 lender2Before = IERC20(USDC).balanceOf(users.lender2);
        uint256 lender3Before = IERC20(USDC).balanceOf(users.lender3);

        // Repay
        vm.startPrank(users.borrower);
        uint256 requiredPayment = calculateRequiredRepayment(loanTerms);
        loanRouter.repay(loanTerms, requiredPayment);
        vm.stopPrank();

        // Verify all lenders received payments
        assertGt(IERC20(USDC).balanceOf(users.lender1), lender1Before, "Lender1 should receive payment");
        assertGt(IERC20(USDC).balanceOf(users.lender2), lender2Before, "Lender2 should receive payment");
        assertGt(IERC20(USDC).balanceOf(users.lender3), lender3Before, "Lender3 should receive payment");
    }

    /*------------------------------------------------------------------------*/
    /* Test: Early repayment with prepayment */
    /*------------------------------------------------------------------------*/

    function test__Repay_WithPrepayment_PartialPrepay() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 1);

        (,, uint64 repaymentDeadline, uint256 balanceBefore) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Warp to repayment window
        warpToNextRepaymentWindow(repaymentDeadline);

        uint256 prepayment = 10_000 * 1e6; // Prepay 10k USDC
        uint256 requiredPayment = calculateRequiredRepayment(loanTerms);

        // Repay with prepayment
        vm.startPrank(users.borrower);
        loanRouter.repay(loanTerms, requiredPayment + prepayment); // Total amount = required + prepayment
        vm.stopPrank();

        // Verify balance reduced by more than normal payment
        (,,, uint256 balanceAfter) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        uint256 balanceReduction = balanceBefore - balanceAfter;

        assertGt(balanceReduction, 0, "Balance should be reduced");
        assertLt(balanceAfter, balanceBefore, "Balance should decrease");
    }

    function test__Repay_FullPrepayment() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 1);

        (,, uint64 repaymentDeadline, uint256 balance) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Warp to repayment window
        warpToNextRepaymentWindow(repaymentDeadline);

        // Prepay entire remaining balance
        uint256 prepayment = balance * 2; // Overpay to ensure full repayment

        // Record borrower's collateral ownership before
        address collateralOwnerBefore = IERC721(address(bundleCollateralWrapper)).ownerOf(wrappedTokenId);
        assertEq(collateralOwnerBefore, address(loanRouter), "Collateral should be with LoanRouter");

        // Repay with full prepayment
        vm.startPrank(users.borrower);
        loanRouter.repay(loanTerms, prepayment);
        vm.stopPrank();

        // Verify loan is fully repaid
        (ILoanRouter.LoanStatus status,,, uint256 finalBalance) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(uint8(status), uint8(ILoanRouter.LoanStatus.Repaid), "Loan should be repaid");
        assertEq(finalBalance, 0, "Balance should be zero");

        // Verify collateral returned to borrower
        assertEq(
            IERC721(address(bundleCollateralWrapper)).ownerOf(wrappedTokenId),
            users.borrower,
            "Collateral should be returned to borrower"
        );
    }

    /*------------------------------------------------------------------------*/
    /* Test: Late repayment (1 interval late) */
    /*------------------------------------------------------------------------*/

    function test__Repay_LatePayment_OneIntervalLate() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 1);

        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Miss the first repayment window entirely
        // Warp to second repayment window (30 days late)
        vm.warp(repaymentDeadline + 1); // Just past first deadline

        // Record balances
        uint256 lender1Before = IERC20(USDC).balanceOf(users.lender1);

        // Repay (should include grace period interest)
        vm.startPrank(users.borrower);
        uint256 requiredPayment = calculateRequiredRepayment(loanTerms);
        loanRouter.repay(loanTerms, requiredPayment);
        vm.stopPrank();

        // Verify lender received payment (including grace period interest)
        uint256 lender1Payment = IERC20(USDC).balanceOf(users.lender1) - lender1Before;
        assertGt(lender1Payment, 0, "Lender should receive payment");
    }

    function test__Repay_LatePayment_TwoIntervalsLate() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 1);

        (,, uint64 repaymentDeadline, uint256 balanceBefore) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Miss two repayment windows (60 days late)
        vm.warp(repaymentDeadline + (REPAYMENT_INTERVAL * 2) + 1);

        // Repay (should include 2 intervals worth of payments + grace period interest)
        vm.startPrank(users.borrower);
        uint256 requiredPayment = calculateRequiredRepayment(loanTerms);
        loanRouter.repay(loanTerms, requiredPayment);
        vm.stopPrank();

        // Verify balance reduced significantly (2 intervals worth)
        (,,, uint256 balanceAfter) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        uint256 balanceReduction = balanceBefore - balanceAfter;

        assertGt(balanceReduction, 0, "Balance should be reduced");
        assertLt(balanceAfter, balanceBefore, "Balance should decrease");
    }

    /*------------------------------------------------------------------------*/
    /* Test: Payment after maturity */
    /*------------------------------------------------------------------------*/

    function test__Repay_AfterMaturity_WithinGracePeriod() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 1);

        (, uint64 maturity,,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Warp to just after maturity but within grace period
        vm.warp(maturity + 1);

        // Should still be able to repay - pay enough to cover everything including exit fee
        vm.startPrank(users.borrower);
        uint256 requiredPayment = calculateRequiredRepayment(loanTerms);
        // Add enough for full prepayment + exit fee
        loanRouter.repay(loanTerms, principal * 2);
        vm.stopPrank();

        // Verify loan still active (not liquidated)
        (ILoanRouter.LoanStatus status,,,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(uint8(status), uint8(ILoanRouter.LoanStatus.Repaid), "Loan should be repaid");
    }

    function test__Repay_AfterMaturity_NearEndOfGracePeriod() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 1);

        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Warp to near end of grace period (but before it ends)
        uint64 gracePeriodEnd = repaymentDeadline + GRACE_PERIOD_DURATION;
        vm.warp(gracePeriodEnd - 1);

        uint256 lender1Before = IERC20(USDC).balanceOf(users.lender1);

        // Should still be able to repay (with maximum grace period interest)
        vm.startPrank(users.borrower);
        uint256 requiredPayment = calculateRequiredRepayment(loanTerms);
        loanRouter.repay(loanTerms, requiredPayment);
        vm.stopPrank();

        // Verify payment was made with grace period interest
        uint256 lender1Payment = IERC20(USDC).balanceOf(users.lender1) - lender1Before;
        assertGt(lender1Payment, 0, "Lender should receive payment with grace interest");
    }

    /*------------------------------------------------------------------------*/
    /* Test: Sequential repayments over loan lifetime */
    /*------------------------------------------------------------------------*/

    function test__Repay_SequentialPayments_FullLoanLifecycle() public {
        uint256 principal = 120_000 * 1e6; // 120k USDC

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 2);

        // Make payments at each interval until loan is paid off
        uint256 paymentCount = 0;
        uint256 maxPayments = (LOAN_DURATION / REPAYMENT_INTERVAL) + 5; // Add buffer

        while (paymentCount < maxPayments) {
            (, uint64 maturity, uint64 repaymentDeadline, uint256 balance) =
                loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

            if (balance == 0) break; // Loan fully repaid

            // Warp to next repayment window
            warpToNextRepaymentWindow(repaymentDeadline);

            // Make payment
            vm.startPrank(users.borrower);
            uint256 requiredPayment = calculateRequiredRepayment(loanTerms);

            // On the last payment, add extra for exit fee
            if (maturity == repaymentDeadline) {
                // This will be the final payment - add enough for exit fee
                requiredPayment += loanTerms.feeSpec.exitFee + 1000 * 1e6; // Add buffer
            }

            loanRouter.repay(loanTerms, requiredPayment);
            vm.stopPrank();

            paymentCount++;
        }

        // Verify loan is eventually fully repaid
        (ILoanRouter.LoanStatus status,,, uint256 finalBalance) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(finalBalance, 0, "Loan should be fully repaid");
        assertEq(uint8(status), uint8(ILoanRouter.LoanStatus.Repaid), "Status should be Repaid");
    }

    /*------------------------------------------------------------------------*/
    /* Test: Early full repayment on first payment */
    /*------------------------------------------------------------------------*/

    function test__Repay_FullRepayment_FirstPayment() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 1);

        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Warp to first repayment window
        warpToNextRepaymentWindow(repaymentDeadline);

        // Calculate required payment (interest + principal for this period) + exit fee + full prepayment
        uint256 requiredPayment = calculateRequiredRepayment(loanTerms);
        (, uint64 maturity,,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // For full prepayment, need to pay: required payment + remaining balance + exit fee
        // The contract will handle distributing to cover everything
        uint256 fullRepaymentAmount = principal * 2; // Give enough to cover everything

        // Pay off entire loan immediately
        vm.startPrank(users.borrower);
        loanRouter.repay(loanTerms, fullRepaymentAmount); // Pay enough to cover full loan + exit fee
        vm.stopPrank();

        // Verify loan fully repaid
        (ILoanRouter.LoanStatus status,,, uint256 finalBalance) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(uint8(status), uint8(ILoanRouter.LoanStatus.Repaid), "Loan should be repaid");
        assertEq(finalBalance, 0, "Balance should be zero");

        // Verify collateral returned
        assertEq(
            IERC721(address(bundleCollateralWrapper)).ownerOf(wrappedTokenId),
            users.borrower,
            "Collateral should be returned"
        );
    }

    /*------------------------------------------------------------------------*/
    /* Test: Repayment failures */
    /*------------------------------------------------------------------------*/

    function test__Repay_RevertWhen_NotBorrower() public {
        uint256 principal = 100_000 * 1e6;

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 1);

        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        warpToNextRepaymentWindow(repaymentDeadline);

        // Calculate required payment before setting up revert expectation
        uint256 requiredPayment = calculateRequiredRepayment(loanTerms);

        // Try to repay as different user
        vm.startPrank(users.lender1);
        vm.expectRevert(ILoanRouter.InvalidCaller.selector);
        loanRouter.repay(loanTerms, requiredPayment);
        vm.stopPrank();
    }

    function test__Repay_RevertWhen_LoanNotActive() public {
        uint256 principal = 100_000 * 1e6;
        uint256 originationFee = principal / 100;
        uint256 exitFee = principal / 200;

        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 1, originationFee, exitFee);

        // Try to repay without borrowing first
        vm.startPrank(users.borrower);
        vm.expectRevert(ILoanRouter.InvalidLoanState.selector);
        loanRouter.repay(loanTerms, 0);
        vm.stopPrank();
    }

    function test__Repay_OutsideRepaymentWindow_NoPaymentMade() public {
        uint256 principal = 100_000 * 1e6;

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 1);

        (,, uint64 repaymentDeadline, uint256 balanceBefore) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Try to repay before repayment window opens
        // Repayment window opens at (repaymentDeadline - REPAYMENT_INTERVAL)
        uint256 beforeWindowOpens = repaymentDeadline - REPAYMENT_INTERVAL - 1;
        vm.warp(beforeWindowOpens);

        // Repay (should not make any payment as outside window)
        vm.startPrank(users.borrower);
        loanRouter.repay(loanTerms, 0);
        vm.stopPrank();

        // Verify balance unchanged
        (,,, uint256 balanceAfter) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(balanceAfter, balanceBefore, "Balance should be unchanged");
    }

    /*------------------------------------------------------------------------*/
    /* Test: Repayment with exit fee */
    /*------------------------------------------------------------------------*/

    function test__Repay_ExitFee_ChargedOnFullRepayment() public {
        uint256 principal = 100_000 * 1e6;

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 1);

        (,, uint64 repaymentDeadline, uint256 balance) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        warpToNextRepaymentWindow(repaymentDeadline);

        uint256 feeRecipientBefore = IERC20(USDC).balanceOf(users.feeRecipient);

        // Pay off entire loan
        vm.startPrank(users.borrower);
        vm.recordLogs();
        loanRouter.repay(loanTerms, balance * 2); // Overpay to ensure full repayment

        // Get the LoanRepaid event and extract adminFee
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 adminFee;

        for (uint256 i = 0; i < logs.length; i++) {
            // LoanRepaid event signature
            if (
                logs[i].topics[0]
                    == keccak256("LoanRepaid(bytes32,address,uint256,uint256,uint256,uint256,uint256,bool)")
            ) {
                // Decode all non-indexed parameters: principal, interest, prepayment, exitFee, adminFee, isRepaid
                (
                    uint256 principalRepaid,
                    uint256 interest,
                    uint256 prepayment,
                    uint256 exitFee,
                    uint256 _adminFee,
                    bool isRepaid
                ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, bool));
                principalRepaid;
                interest;
                prepayment;
                exitFee;
                isRepaid;
                adminFee = _adminFee;
                break;
            }
        }
        vm.stopPrank();

        // Verify exit fee was charged
        uint256 feeRecipientAfter = IERC20(USDC).balanceOf(users.feeRecipient);
        uint256 exitFeeCharged = feeRecipientAfter - feeRecipientBefore - adminFee;

        assertEq(exitFeeCharged, loanTerms.feeSpec.exitFee, "Exit fee should be charged");
    }

    /*------------------------------------------------------------------------*/
    /* Test: Multiple tranches with different rates */
    /*------------------------------------------------------------------------*/

    function test__Repay_MultipleTranches_DifferentRates_ProperDistribution() public {
        uint256 principal = 300_000 * 1e6; // 300k USDC

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 3);

        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        warpToNextRepaymentWindow(repaymentDeadline);

        uint256 lender1Before = IERC20(USDC).balanceOf(users.lender1);
        uint256 lender2Before = IERC20(USDC).balanceOf(users.lender2);
        uint256 lender3Before = IERC20(USDC).balanceOf(users.lender3);

        // Repay
        vm.startPrank(users.borrower);
        uint256 requiredPayment = calculateRequiredRepayment(loanTerms);
        loanRouter.repay(loanTerms, requiredPayment);
        vm.stopPrank();

        uint256 lender1Payment = IERC20(USDC).balanceOf(users.lender1) - lender1Before;
        uint256 lender2Payment = IERC20(USDC).balanceOf(users.lender2) - lender2Before;
        uint256 lender3Payment = IERC20(USDC).balanceOf(users.lender3) - lender3Before;

        // All lenders should receive payments
        assertGt(lender1Payment, 0, "Lender1 should receive payment");
        assertGt(lender2Payment, 0, "Lender2 should receive payment");
        assertGt(lender3Payment, 0, "Lender3 should receive payment");

        // Higher rate tranches should receive more interest
        // Lender3 has highest rate (RATE_14_PCT)
        // Lender2 has middle rate (RATE_10_PCT)
        // Lender1 has lowest rate (RATE_8_PCT)
        // Note: Payments also include principal, so this is approximate
        assertGt(lender3Payment, lender2Payment, "Lender3 should receive more than Lender2");
        assertGt(lender2Payment, lender1Payment, "Lender2 should receive more than Lender1");
    }

    /*------------------------------------------------------------------------*/
    /* Test: Blacklisted lender - repayment still succeeds but lender does not receive payment */
    /*------------------------------------------------------------------------*/

    function test__Repay_BlacklistedLender_SingleTranche_NoPayment() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 1);

        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Blacklist lender1 using actual USDC blacklist function
        // USDC blacklister address on Arbitrum
        address usdcBlacklister = 0xAC5b4946A8C29Eafb42e1742b3AB82e6D5771329;
        vm.startPrank(usdcBlacklister);
        (bool success,) = USDC.call(abi.encodeWithSignature("blacklist(address)", users.lender1));
        require(success, "Blacklist call failed");
        vm.stopPrank();

        // Warp to repayment window
        warpToNextRepaymentWindow(repaymentDeadline);

        // Record balances
        uint256 lender1Before = IERC20(USDC).balanceOf(users.lender1);
        uint256 borrowerBefore = IERC20(USDC).balanceOf(users.borrower);

        // Repay
        vm.startPrank(users.borrower);
        uint256 requiredPayment = calculateRequiredRepayment(loanTerms);
        loanRouter.repay(loanTerms, requiredPayment);
        vm.stopPrank();

        // Verify lender did NOT receive payment (still blacklisted)
        assertEq(IERC20(USDC).balanceOf(users.lender1), lender1Before, "Blacklisted lender should not receive payment");

        // Verify borrower paid
        assertLt(IERC20(USDC).balanceOf(users.borrower), borrowerBefore, "Borrower should have paid");
    }

    function test__Repay_BlacklistedLender_MultipleTranches_OneBlacklisted() public {
        uint256 principal = 300_000 * 1e6; // 300k USDC

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 3);

        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Blacklist lender2 only (middle tranche)
        address usdcBlacklister = 0xAC5b4946A8C29Eafb42e1742b3AB82e6D5771329;
        vm.startPrank(usdcBlacklister);
        (bool success,) = USDC.call(abi.encodeWithSignature("blacklist(address)", users.lender2));
        require(success, "Blacklist call failed");
        vm.stopPrank();

        // Warp to repayment window
        warpToNextRepaymentWindow(repaymentDeadline);

        // Record balances
        uint256 lender1Before = IERC20(USDC).balanceOf(users.lender1);
        uint256 lender2Before = IERC20(USDC).balanceOf(users.lender2);
        uint256 lender3Before = IERC20(USDC).balanceOf(users.lender3);

        // Repay
        vm.startPrank(users.borrower);
        uint256 requiredPayment = calculateRequiredRepayment(loanTerms);
        loanRouter.repay(loanTerms, requiredPayment);
        vm.stopPrank();

        uint256 lender1Payment = IERC20(USDC).balanceOf(users.lender1) - lender1Before;
        uint256 lender2Payment = IERC20(USDC).balanceOf(users.lender2) - lender2Before;
        uint256 lender3Payment = IERC20(USDC).balanceOf(users.lender3) - lender3Before;

        // Verify lender1 and lender3 received their payments (not blacklisted)
        assertGt(lender1Payment, 0, "Lender1 should receive payment");
        assertGt(lender3Payment, 0, "Lender3 should receive payment");

        // Verify lender2 did NOT receive payment (blacklisted)
        assertEq(lender2Payment, 0, "Blacklisted lender2 should not receive payment");
    }

    function test__Repay_BlacklistedLender_FullRepayment_NoPayment() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 1);

        (,, uint64 repaymentDeadline, uint256 balance) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Blacklist lender1
        address usdcBlacklister = 0xAC5b4946A8C29Eafb42e1742b3AB82e6D5771329;
        vm.startPrank(usdcBlacklister);
        (bool success,) = USDC.call(abi.encodeWithSignature("blacklist(address)", users.lender1));
        require(success, "Blacklist call failed");
        vm.stopPrank();

        // Warp to repayment window
        warpToNextRepaymentWindow(repaymentDeadline);

        // Record balances
        uint256 lender1Before = IERC20(USDC).balanceOf(users.lender1);

        // Pay off entire loan
        vm.startPrank(users.borrower);
        uint256 fullRepaymentAmount = balance * 2; // Overpay to ensure full repayment
        loanRouter.repay(loanTerms, fullRepaymentAmount);
        vm.stopPrank();

        // Verify loan fully repaid
        (ILoanRouter.LoanStatus status,,, uint256 finalBalance) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(uint8(status), uint8(ILoanRouter.LoanStatus.Repaid), "Loan should be repaid");
        assertEq(finalBalance, 0, "Balance should be zero");

        // Verify lender1 did not receive payment
        assertEq(IERC20(USDC).balanceOf(users.lender1), lender1Before, "Blacklisted lender should not receive payment");

        // Verify collateral returned to borrower despite blacklisted lender
        assertEq(
            IERC721(address(bundleCollateralWrapper)).ownerOf(wrappedTokenId),
            users.borrower,
            "Collateral should be returned"
        );
    }

    function test__Repay_BlacklistedLender_LatePayment_NoPayment() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 1);

        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Blacklist lender1
        address usdcBlacklister = 0xAC5b4946A8C29Eafb42e1742b3AB82e6D5771329;
        vm.startPrank(usdcBlacklister);
        (bool success,) = USDC.call(abi.encodeWithSignature("blacklist(address)", users.lender1));
        require(success, "Blacklist call failed");
        vm.stopPrank();

        // Miss the first repayment window (late payment)
        vm.warp(repaymentDeadline + 1);

        // Record balances
        uint256 lender1Before = IERC20(USDC).balanceOf(users.lender1);

        // Repay late (includes grace period interest)
        vm.startPrank(users.borrower);
        uint256 requiredPayment = calculateRequiredRepayment(loanTerms);
        loanRouter.repay(loanTerms, requiredPayment);
        vm.stopPrank();

        // Verify lender did not receive payment
        assertEq(IERC20(USDC).balanceOf(users.lender1), lender1Before, "Blacklisted lender should not receive payment");
    }

    /*------------------------------------------------------------------------*/
    /* Test: Malformed supportsInterface - repayment DOS fix */
    /*------------------------------------------------------------------------*/

    function test__Repay_MalformedSupportsInterface_NoDoS() public {
        uint256 principal = 200_000 * 1e6; // 200k USDC, 2 tranches

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 2);

        // Get tranche token IDs: lender1 owns [0], lender2 owns [1]
        uint256[] memory tokenIds = loanRouter.loanTokenIds(loanTerms);

        // Attacker (lender2) transfers their tranche NFT to a contract with a
        // malformed supportsInterface that returns 2 instead of 0 or 1.
        // Before the fix this caused abi.decode(returnData, (bool)) to revert
        // inside _supportsHooksInterface, bricking repay for all lenders.
        MalformedSupportsInterfaceOwner maliciousOwner = new MalformedSupportsInterfaceOwner();
        vm.prank(users.lender2);
        loanRouter.safeTransferFrom(users.lender2, address(maliciousOwner), tokenIds[1]);

        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        warpToNextRepaymentWindow(repaymentDeadline);

        uint256 lender1Before = IERC20(USDC).balanceOf(users.lender1);

        // Repay must succeed despite a tranche being held by the malicious contract
        vm.startPrank(users.borrower);
        uint256 requiredPayment = calculateRequiredRepayment(loanTerms);
        loanRouter.repay(loanTerms, requiredPayment);
        vm.stopPrank();

        // Verify lender1 (honest tranche) received payment
        assertGt(IERC20(USDC).balanceOf(users.lender1), lender1Before, "Lender1 should receive payment");

        // Verify loan state advanced
        (,, uint64 newDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(newDeadline, repaymentDeadline + REPAYMENT_INTERVAL, "Repayment deadline should advance");
    }

    function test__Repay_BlacklistedLender_AllTranchesBlacklisted() public {
        uint256 principal = 300_000 * 1e6; // 300k USDC

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 3);

        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Blacklist all lenders
        address usdcBlacklister = 0xAC5b4946A8C29Eafb42e1742b3AB82e6D5771329;
        vm.startPrank(usdcBlacklister);
        (bool success1,) = USDC.call(abi.encodeWithSignature("blacklist(address)", users.lender1));
        require(success1, "Blacklist call failed for lender1");
        (bool success2,) = USDC.call(abi.encodeWithSignature("blacklist(address)", users.lender2));
        require(success2, "Blacklist call failed for lender2");
        (bool success3,) = USDC.call(abi.encodeWithSignature("blacklist(address)", users.lender3));
        require(success3, "Blacklist call failed for lender3");
        vm.stopPrank();

        // Warp to repayment window
        warpToNextRepaymentWindow(repaymentDeadline);

        // Record balances
        uint256 lender1Before = IERC20(USDC).balanceOf(users.lender1);
        uint256 lender2Before = IERC20(USDC).balanceOf(users.lender2);
        uint256 lender3Before = IERC20(USDC).balanceOf(users.lender3);

        // Repay
        vm.startPrank(users.borrower);
        uint256 requiredPayment = calculateRequiredRepayment(loanTerms);
        loanRouter.repay(loanTerms, requiredPayment);
        vm.stopPrank();

        // Verify no lenders received payments
        assertEq(IERC20(USDC).balanceOf(users.lender1), lender1Before, "Blacklisted lender1 should not receive payment");
        assertEq(IERC20(USDC).balanceOf(users.lender2), lender2Before, "Blacklisted lender2 should not receive payment");
        assertEq(IERC20(USDC).balanceOf(users.lender3), lender3Before, "Blacklisted lender3 should not receive payment");
    }

    /*------------------------------------------------------------------------*/
    /* Test: Malicious interest rate model exploit attempt */
    /*------------------------------------------------------------------------*/

    function test__Repay_RevertWhen_MaliciousInterestRateModel_AttemptsToExtractFunds() public {
        // Deploy malicious interest rate model
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 100 ether);

        vm.startPrank(attacker);
        MaliciousInterestRateModel maliciousModel = new MaliciousInterestRateModel();
        vm.stopPrank();

        // Send some USDC to LoanRouter (simulating funds sitting in the contract that attacker wants to steal)
        uint256 fundsInRouter = 50_000 * 1e6; // 50k USDC
        deal(USDC, address(loanRouter), fundsInRouter);

        // Transfer collateral to attacker
        vm.prank(users.borrower);
        IERC721(address(bundleCollateralWrapper)).transferFrom(users.borrower, attacker, wrappedTokenId);

        // Fund attacker with USDC for repayment
        deal(USDC, attacker, 200_000 * 1e6);

        // Create loan terms with malicious interest rate model
        uint256 principal = 100_000 * 1e6; // 100k USDC
        uint256 originationFee = principal / 100; // 1%
        uint256 exitFee = principal / 200; // 0.5%

        // Create loan terms with attacker as borrower and malicious model
        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(attacker, principal, 2, originationFee, exitFee);
        loanTerms.interestRateModel = address(maliciousModel);

        bytes32 loanTermsHash = loanRouter.loanTermsHash(loanTerms);

        // Setup deposits for tranches
        vm.startPrank(users.lender1);
        uint256 depositAmount1 = (loanTerms.trancheSpecs[0].amount * 10016 * 1e12) / 10000;
        depositTimelock.deposit(address(loanRouter), loanTermsHash, USDAI, depositAmount1, loanTerms.expiration);
        vm.stopPrank();

        vm.startPrank(users.lender2);
        uint256 depositAmount2 = (loanTerms.trancheSpecs[1].amount * 10016 * 1e12) / 10000;
        depositTimelock.deposit(address(loanRouter), loanTermsHash, USDAI, depositAmount2, loanTerms.expiration);
        vm.stopPrank();

        // Borrow as attacker
        vm.startPrank(attacker);
        // Approve collateral and USDC
        IERC20(USDC).approve(address(loanRouter), type(uint256).max);
        IERC721(address(bundleCollateralWrapper)).approve(address(loanRouter), wrappedTokenId);

        ILoanRouter.LenderDepositInfo[] memory lenderDepositInfos = createDepositTimelockInfos(2);
        loanRouter.borrow(loanTerms, lenderDepositInfos);
        vm.stopPrank();

        // Get loan state
        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanTermsHash);

        // Warp to repayment window
        warpToNextRepaymentWindow(repaymentDeadline);

        // Record router balance before attack
        uint256 routerBalanceBefore = IERC20(USDC).balanceOf(address(loanRouter));

        // Attempt to repay with malicious model - should revert with InvalidAmount
        vm.startPrank(attacker);
        uint256 requiredPayment = calculateRequiredRepayment(loanTerms);

        // Expect revert due to totalRepayment > transferredRepayment check in _repayLenders()
        vm.expectRevert(ILoanRouter.InvalidAmount.selector);
        loanRouter.repay(loanTerms, requiredPayment);
        vm.stopPrank();

        // Verify router balance unchanged (attack failed)
        uint256 routerBalanceAfter = IERC20(USDC).balanceOf(address(loanRouter));
        assertEq(routerBalanceAfter, routerBalanceBefore, "Router balance should be unchanged after failed attack");
    }
}

/*------------------------------------------------------------------------*/
/* Malformed supportsInterface owner - returns 2 instead of 0 or 1 */
/*------------------------------------------------------------------------*/

contract MalformedSupportsInterfaceOwner is IERC721Receiver {
    function supportsInterface(
        bytes4
    ) external pure returns (bool) {
        assembly {
            mstore(0x00, 2)
            return(0x00, 0x20)
        }
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/*------------------------------------------------------------------------*/
/* Malicious Interest Rate Model */
/*------------------------------------------------------------------------*/

import {IInterestRateModel} from "src/interfaces/IInterestRateModel.sol";

contract MaliciousInterestRateModel is IInterestRateModel {
    function INTEREST_RATE_MODEL_NAME() external pure returns (string memory) {
        return "Malicious Interest Rate Model";
    }

    function INTEREST_RATE_MODEL_VERSION() external pure returns (string memory) {
        return "1.0";
    }

    function repayment(
        ILoanRouter.LoanTerms calldata terms,
        uint256,
        uint64,
        uint64,
        uint64
    )
        external
        pure
        returns (
            uint256 principalPayment,
            uint256 interestPayment,
            uint256[] memory tranchePrincipals,
            uint256[] memory trancheInterests,
            uint64 servicedIntervals
        )
    {
        tranchePrincipals = new uint256[](terms.trancheSpecs.length);
        trancheInterests = new uint256[](terms.trancheSpecs.length);

        uint256 scaleFactor = 10 ** (18 - 6);

        principalPayment = 1000 * scaleFactor; // 1000 USDC scaled
        interestPayment = 100 * scaleFactor; // 100 USDC scaled

        // Inflate the individual tranche values to extract more
        for (uint8 i = 0; i < terms.trancheSpecs.length; i++) {
            tranchePrincipals[i] = 25_000 * scaleFactor; // 25k USDC per tranche
            trancheInterests[i] = 5_000 * scaleFactor; // 5k USDC per tranche
        }

        servicedIntervals = 1;
    }
}
