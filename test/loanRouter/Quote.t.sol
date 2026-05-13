// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {BaseTest} from "../Base.t.sol";
import {ILoanRouter} from "src/interfaces/ILoanRouter.sol";
import {SimpleInterestRateModel} from "src/rates/SimpleInterestRateModel.sol";
import {Vm} from "forge-std/Vm.sol";

contract LoanRouterQuoteTest is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Helper: Setup loan */
    /*------------------------------------------------------------------------*/

    function setupLoan(
        uint256 principal,
        uint256 numTranches,
        address interestRateModel
    ) internal returns (ILoanRouter.LoanTerms memory loanTerms, bytes32 loanTermsHash) {
        uint256 originationFee = principal / 100; // 1% origination fee
        uint256 exitFee = principal / 200; // 0.5% exit fee

        loanTerms = createLoanTerms(users.borrower, principal, numTranches, originationFee, exitFee, interestRateModel);
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

    function test__Quote_OnTime() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 1, address(interestRateModel));

        // Warp one second into loan
        warp(1);

        (uint256 principalPayment, uint256 interestPayment, uint256 feesPayment) = loanRouter.quote(loanTerms);

        assertEq(principalPayment + interestPayment + feesPayment, 3220362657);
    }

    /*------------------------------------------------------------------------*/
    /* Test: Late repayment */
    /*------------------------------------------------------------------------*/

    function test__Quote_LatePayment_OneIntervalLate() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 1, address(interestRateModel));

        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Miss the first repayment window entirely
        // Warp to second repayment window (30 days late)
        vm.warp(repaymentDeadline + 1); // Just past first deadline

        (uint256 principalPayment, uint256 interestPayment, uint256 feesPayment) = loanRouter.quote(loanTerms);

        assertEq(principalPayment + interestPayment + feesPayment, 3220362816);
    }

    function test__Quote_LatePayment_TwoIntervalsLate() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 1, address(interestRateModel));

        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Miss two repayment windows (60 days late)
        vm.warp(repaymentDeadline + (REPAYMENT_INTERVAL * 2) + 1);

        (uint256 principalPayment, uint256 interestPayment, uint256 feesPayment) = loanRouter.quote(loanTerms);

        assertEq(principalPayment + interestPayment + feesPayment, 10072046873);
    }

    /*------------------------------------------------------------------------*/
    /* Test: Inactive Loan */
    /*------------------------------------------------------------------------*/

    function test__Quote_InactiveLoan() public view {
        uint256 principal = 100_000 * 1e6; // 100k USDC
        uint256 originationFee = principal / 100; // 1% origination fee
        uint256 exitFee = principal / 200; // 0.5% exit fee
        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 1, originationFee, exitFee);

        (uint256 principalPayment, uint256 interestPayment, uint256 feesPayment) = loanRouter.quote(loanTerms);

        assertEq(principalPayment + interestPayment + feesPayment, 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: Last repayment with exit fee */
    /*------------------------------------------------------------------------*/

    function test__Quote_LastRepayment_IncludesExitFee() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC
        uint256 originationFee = principal / 100; // 1% origination fee
        uint256 exitFee = principal / 200; // 0.5% exit fee = 500 USDC

        // Create short-duration loan (60 days = 2 intervals of 30 days)
        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 1, originationFee, exitFee);
        loanTerms.duration = 60 days;

        bytes32 loanTermsHash = loanRouter.loanTermsHash(loanTerms);

        // Setup deposit
        vm.startPrank(users.lender1);
        uint256 depositAmount = (loanTerms.trancheSpecs[0].amount * 10016 * 1e12) / 10000;
        depositTimelock.deposit(address(loanRouter), loanTermsHash, USDAI, depositAmount, loanTerms.expiration);
        vm.stopPrank();

        // Borrow
        vm.startPrank(users.borrower);
        ILoanRouter.LenderDepositInfo[] memory lenderDepositInfos = createDepositTimelockInfos(1);
        loanRouter.borrow(loanTerms, lenderDepositInfos);
        vm.stopPrank();

        // Make first repayment
        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanTermsHash);
        vm.warp(repaymentDeadline - REPAYMENT_INTERVAL + 1);

        (uint256 principalPayment1, uint256 interestPayment1, uint256 feesPayment1) = loanRouter.quote(loanTerms);

        vm.startPrank(users.borrower);
        loanRouter.repay(loanTerms, principalPayment1 + interestPayment1 + feesPayment1); // Add buffer
        vm.stopPrank();

        // Warp to final repayment window
        (,, uint64 newRepaymentDeadline,) = loanRouter.loanState(loanTermsHash);
        vm.warp(newRepaymentDeadline - REPAYMENT_INTERVAL + 1);

        // Get quote for final repayment - should include exit fee
        (uint256 principalPayment2, uint256 interestPayment2, uint256 feesPayment2) = loanRouter.quote(loanTerms);

        // Record logs to capture LoanRepaid event
        vm.recordLogs();

        vm.startPrank(users.borrower);
        loanRouter.repay(loanTerms, principalPayment2 + interestPayment2 + feesPayment2);
        vm.stopPrank();

        // Get recorded logs
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Find LoanRepaid event
        bool foundLoanRepaid = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("LoanRepaid(bytes32,address,uint256,uint256,uint256,uint256,bool)")) {
                foundLoanRepaid = true;

                // Decode event data (first two params are in topics)
                (,, uint256 eventPrepayment, uint256 eventExitFee, bool isRepaid) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, bool));

                // Verify event parameters
                assertEq(isRepaid, true);

                // Verify prepayment is 0
                assertEq(eventPrepayment, 0);

                // Verify exit fee matches expected
                assertEq(eventExitFee, exitFee);

                break;
            }
        }

        // Ensure we found the LoanRepaid event
        assertTrue(foundLoanRepaid, "LoanRepaid event not found");

        (uint256 principalPayment3, uint256 interestPayment3, uint256 feesPayment3) = loanRouter.quote(loanTerms);

        // Verify loan is repaid
        assertEq(principalPayment3 + interestPayment3 + feesPayment3, 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: Includes exit fee after multiple missed payments */
    /*------------------------------------------------------------------------*/

    function test__Quote_IncludesExitFee_AfterMultipleMissedPayments_WithSimpleIRM() public {
        uint256 principal = 100_000 * 1e6;

        address simpleInterestRateModel = address(new SimpleInterestRateModel());

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 1, simpleInterestRateModel);

        vm.warp(block.timestamp + LOAN_DURATION);

        loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        (,,, uint256 scaledBalance) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        (uint256 principalPayment,, uint256 feesPayment) = loanRouter.quote(loanTerms, uint64(block.timestamp));

        assertEq(scaledBalance, principalPayment * 1e12, "Scaled balance should be correct");
        assertGt(feesPayment, 0, "Fees payment should be positive");
    }

    function test__Quote_IncludesExitFee_AfterMultipleMissedPayments_WithAmortizedIRM() public {
        uint256 principal = 100_000 * 1e6;

        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 1, address(interestRateModel));

        vm.warp(block.timestamp + LOAN_DURATION);

        loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        (,,, uint256 scaledBalance) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        (uint256 principalPayment,, uint256 feesPayment) = loanRouter.quote(loanTerms, uint64(block.timestamp));

        assertEq(scaledBalance, principalPayment * 1e12, "Scaled balance should be correct");
        assertGt(feesPayment, 0, "Fees payment should be positive");
    }
}
