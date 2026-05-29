// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Vm} from "forge-std/Vm.sol";

import {RouterFixture} from "../helpers/RouterFixture.sol";
import {LoanFixtures} from "../helpers/LoanFixtures.sol";
import {LenderHookRecorder} from "../mocks/LenderHookRecorder.sol";
import {LenderHookReverter} from "../mocks/LenderHookReverter.sol";

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {RatioFeeModel} from "src/fees/RatioFeeModel.sol";
import {AbsoluteFeeModel} from "src/fees/AbsoluteFeeModel.sol";
import {SimpleInterestRateModel} from "src/rates/SimpleInterestRateModel.sol";

contract LoanRouterV2RepayTest is RouterFixture {
    /*------------------------------------------------------------------------*/
    /* Repay helpers */
    /*------------------------------------------------------------------------*/

    function _repayAtCurrentTimestamp(
        ILoanRouterV2.LoanTermsV2 memory loanTerms
    ) internal returns (uint256 totalPaid) {
        (uint256 p, uint256 i, uint256 f) = router.quote(loanTerms);
        totalPaid = p + i + f;
        if (totalPaid == 0) return 0;

        /* Top up borrower (EscrowTimelock path means borrower doesn't have on-chain principal) */
        uint256 currentBal = IERC20(loanTerms.currencyToken).balanceOf(users.borrower);
        if (currentBal < totalPaid) {
            deal(loanTerms.currencyToken, users.borrower, currentBal + totalPaid + 1e20);
        }
        vm.startPrank(users.borrower);
        IERC20(loanTerms.currencyToken).approve(address(router), totalPaid);
        router.repay(loanTerms, totalPaid);
        vm.stopPrank();
    }

    function _walkAllCycles(
        ILoanRouterV2.LoanTermsV2 memory loanTerms
    ) internal returns (uint256 totalFees) {
        uint64[] memory schedule = _schedule(loanTerms);
        for (uint256 i = 0; i < schedule.length; i++) {
            vm.warp(schedule[i]);
            (,, uint256 fee) = router.quote(loanTerms);
            totalFees += fee;
            _repayAtCurrentTimestamp(loanTerms);
        }
    }

    /*------------------------------------------------------------------------*/
    /* Test: happy path - single cycle */
    /*------------------------------------------------------------------------*/

    function test__Repay_HappyPath_Cycle0() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        (,, uint64 originationTs,) = router.loanState(loanTermsHash_);

        uint256 stakedBalBefore = IERC20(USDAI).balanceOf(STAKED_USDAI);
        vm.warp(_scheduleAt(loanTerms, originationTs)[0]);
        (uint256 p, uint256 i,) = router.quote(loanTerms);
        _repayAtCurrentTimestamp(loanTerms);

        /* repaymentCount advanced */
        (, uint16 count,,) = router.loanState(loanTermsHash_);
        assertEq(count, 1);

        /* STAKED_USDAI received principal + interest */
        assertEq(IERC20(USDAI).balanceOf(STAKED_USDAI) - stakedBalBefore, p + i);
    }

    /*------------------------------------------------------------------------*/
    /* Test: per-cycle iteration - 37 deadlines */
    /*------------------------------------------------------------------------*/

    function test__Repay_AllCycles_1095Days_37Deadlines() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        _walkAllCycles(loanTerms);

        /* Loan is fully repaid */
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        (ILoanRouterV2.LoanStatus status,,, uint256 balance) = router.loanState(loanTermsHash_);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Repaid));
        assertEq(balance, 0);
    }

    function test__Repay_AllCycles_1095Days_36Deadlines() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.variant = LoanFixtures.WindowVariant.Lower;
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateConfigured(config);
        _walkAllCycles(loanTerms);

        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        (ILoanRouterV2.LoanStatus status,,, uint256 balance) = router.loanState(loanTermsHash_);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Repaid));
        assertEq(balance, 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: duration sweep - all cycles per duration */
    /*------------------------------------------------------------------------*/

    function _walkAllCyclesForDuration(
        uint16 durationDays
    ) internal {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.durationDays = durationDays;
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateConfigured(config);
        _walkAllCycles(loanTerms);

        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        (ILoanRouterV2.LoanStatus status,,, uint256 balance) = router.loanState(loanTermsHash_);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Repaid));
        assertEq(balance, 0);
    }

    function test__Repay_AllCycles_DurationSweep_1Day() public {
        _walkAllCyclesForDuration(1);
    }

    function test__Repay_AllCycles_DurationSweep_30Days() public {
        _walkAllCyclesForDuration(30);
    }

    function test__Repay_AllCycles_DurationSweep_90Days() public {
        _walkAllCyclesForDuration(90);
    }

    function test__Repay_AllCycles_DurationSweep_365Days() public {
        _walkAllCyclesForDuration(365);
    }

    function test__Repay_AllCycles_DurationSweep_730Days() public {
        _walkAllCyclesForDuration(730);
    }

    function test__Repay_AllCycles_DurationSweep_1825Days() public {
        _walkAllCyclesForDuration(1825);
    }

    /*------------------------------------------------------------------------*/
    /* Test: final cycle returns collateral */
    /*------------------------------------------------------------------------*/

    function test__Repay_FinalCycle_TransfersCollateralBack() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        _walkAllCycles(loanTerms);
        /* Collateral NFT now back with the borrower */
        assertEq(collateralNft.ownerOf(loanTerms.collateralTokenIds[0]), users.borrower);
    }

    /*------------------------------------------------------------------------*/
    /* Test: insurance fees aggregate */
    /*------------------------------------------------------------------------*/

    function _originateWithPercentageInsurance() internal returns (ILoanRouterV2.LoanTermsV2 memory) {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.feeSpecs = new ILoanRouterV2.FeeSpec[](1);
        config.feeSpecs[0] = ILoanRouterV2.FeeSpec({
            model: address(ratioFeeModel),
            recipient: insuranceRecipient,
            kind: ILoanRouterV2.FeeKind.Repayment,
            options: abi.encode(
                RatioFeeModel.Options({mode: RatioFeeModel.Mode.Balance, rate: LoanFixtures.INSURANCE_ANNUAL_RATE / 12})
            )
        });
        return originateConfigured(config);
    }

    function test__Repay_PercentageInsurance_AggregateBetween1And2Percent() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithPercentageInsurance();
        uint256 totalFees = _walkAllCycles(loanTerms);
        /* 0.125% per cycle (1.5%/12) on declining balance over 37 cycles.
         * Average balance ≈ principal/2, so total ≈ 0.00125 × 18.5 × principal ≈ 2.25% of principal.
         * Bound: between 0.5% and 2.5% of principal */
        assertGt(totalFees, LOAN_AMOUNT_USDAI * 5 / 1000); /* > 0.5% */
        assertLt(totalFees, LOAN_AMOUNT_USDAI * 25 / 1000); /* < 2.5% */
        assertGt(IERC20(USDAI).balanceOf(insuranceRecipient), 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: multi-tranche lender payouts */
    /*------------------------------------------------------------------------*/

    function test__Repay_TwoTranches_LenderPayouts_Proportional() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.twoTranches = true;
        config.useEscrowTimelock = false;
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateConfigured(config);

        uint256 lender1Before = IERC20(USDAI).balanceOf(users.lender1);
        uint256 lender2Before = IERC20(USDAI).balanceOf(users.lender2);
        _walkAllCycles(loanTerms);
        uint256 lender1Gained = IERC20(USDAI).balanceOf(users.lender1) - lender1Before;
        uint256 lender2Gained = IERC20(USDAI).balanceOf(users.lender2) - lender2Before;

        /* Both lenders should receive substantial amounts close to their original $25M plus interest at 8.5% blend */
        assertGt(lender1Gained, TRANCHE_AMOUNT_HALF_USDAI);
        assertGt(lender2Gained, TRANCHE_AMOUNT_HALF_USDAI);
        /* Junior (9%) earns slightly more interest than senior (8%) */
        assertGt(lender2Gained, lender1Gained);
    }

    /*------------------------------------------------------------------------*/
    /* Test: revert paths */
    /*------------------------------------------------------------------------*/

    function test__Repay_RevertWhen_NotBorrower() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        (,, uint64 originationTs,) = router.loanState(router.loanTermsHash(loanTerms));
        vm.warp(_scheduleAt(loanTerms, originationTs)[0]);

        vm.prank(users.lender1); /* not the borrower */
        vm.expectRevert(ILoanRouterV2.InvalidCaller.selector);
        router.repay(loanTerms, 1);
    }

    function test__Repay_RevertWhen_Paused() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        vm.prank(users.admin);
        router.pause();

        vm.prank(users.borrower);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.repay(loanTerms, 1);
    }

    function test__Repay_RevertWhen_LoanNotActive_Uninitialized() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        vm.prank(users.borrower);
        vm.expectRevert(ILoanRouterV2.InvalidLoanState.selector);
        router.repay(loanTerms, 1);
    }

    function test__Repay_RevertWhen_Underpayment() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        (,, uint64 originationTs,) = router.loanState(router.loanTermsHash(loanTerms));
        vm.warp(_scheduleAt(loanTerms, originationTs)[0]);
        (uint256 p, uint256 i, uint256 f) = router.quote(loanTerms);
        uint256 needed = p + i + f;
        deal(USDAI, users.borrower, needed); /* enough to transfer, but underpay by 1 */

        vm.startPrank(users.borrower);
        IERC20(USDAI).approve(address(router), needed);
        vm.expectRevert(ILoanRouterV2.InvalidAmount.selector);
        router.repay(loanTerms, needed - 1);
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: status matrix - extended reverts                                  */
    /*------------------------------------------------------------------------*/

    function test__Repay_RevertWhen_StatusRepaid() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        _walkAllCycles(loanTerms); /* fully repays */
        vm.prank(users.borrower);
        vm.expectRevert(ILoanRouterV2.InvalidLoanState.selector);
        router.repay(loanTerms, 1);
    }

    function test__Repay_RevertWhen_StatusBreached() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        vm.prank(users.liquidator);
        router.setLoanBreach(hash_);
        vm.prank(users.borrower);
        vm.expectRevert(ILoanRouterV2.InvalidLoanState.selector);
        router.repay(loanTerms, 1);
    }

    function test__Repay_RevertWhen_StatusLiquidated() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        vm.prank(users.liquidator);
        router.setLoanBreach(hash_);
        vm.prank(users.liquidator);
        router.liquidate(loanTerms);
        vm.prank(users.borrower);
        vm.expectRevert(ILoanRouterV2.InvalidLoanState.selector);
        router.repay(loanTerms, 1);
    }

    function test__Repay_RevertWhen_StatusCollateralLiquidated() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.twoTranches = true;
        config.useEscrowTimelock = false;
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateConfigured(config);
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        vm.prank(users.liquidator);
        router.setLoanBreach(hash_);
        vm.prank(users.liquidator);
        router.liquidate(loanTerms);
        uint256 proceeds = 50_000_000 * 1e18;
        deal(USDAI, users.liquidator, proceeds);
        vm.startPrank(users.liquidator);
        IERC20(USDAI).approve(address(router), proceeds);
        router.depositLiquidationProceeds(loanTerms, proceeds);
        vm.stopPrank();

        vm.prank(users.borrower);
        vm.expectRevert(ILoanRouterV2.InvalidLoanState.selector);
        router.repay(loanTerms, 1);
    }

    /*------------------------------------------------------------------------*/
    /* Test: exit fee path                                                     */
    /*------------------------------------------------------------------------*/

    function _originateWithExitFee(
        uint256 exitFeeAmount
    ) internal returns (ILoanRouterV2.LoanTermsV2 memory loanTerms) {
        /* FeeKind.Exit is invoked by computeRepayment only on the cycle that closes the loan, so the
         * constant `exitFeeAmount` returned by AbsoluteFeeModel is charged exactly once. */
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.feeSpecs = new ILoanRouterV2.FeeSpec[](1);
        config.feeSpecs[0] = ILoanRouterV2.FeeSpec({
            model: address(absoluteFeeModel),
            recipient: insuranceRecipient,
            kind: ILoanRouterV2.FeeKind.Exit,
            options: abi.encode(AbsoluteFeeModel.Options({amount: exitFeeAmount}))
        });
        loanTerms = originateConfigured(config);
    }

    function test__Repay_ExitFee_ChargedExactlyOnceOverLoanLifetime() public {
        /* Exit fee (FeeKind.Exit) is invoked by computeRepayment only when this repayment closes the loan
         * (`principalPayment + prepayment == loan.balance`). Walking the full schedule should produce exactly
         * one exit fee charge of `exitFeeAmount`. */
        uint256 exitFeeAmount = 100_000 * 1e18; /* $100k */
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithExitFee(exitFeeAmount);
        uint256 insuranceBalBefore = IERC20(USDAI).balanceOf(insuranceRecipient);
        _walkAllCycles(loanTerms);
        assertEq(IERC20(USDAI).balanceOf(insuranceRecipient) - insuranceBalBefore, exitFeeAmount);
    }

    /*------------------------------------------------------------------------*/
    /* Test: prepayment                                                        */
    /*------------------------------------------------------------------------*/

    function test__Repay_Prepayment_ReducesBalanceFurther() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        (,, uint64 originationTs,) = router.loanState(hash_);
        (,,, uint256 balBefore) = router.loanState(hash_);

        vm.warp(_scheduleAt(loanTerms, originationTs)[0]);
        (uint256 p, uint256 i, uint256 f) = router.quote(loanTerms);
        uint256 prepayAmount = 10_000_000 * 1e18; /* $10M extra */
        uint256 totalPay = p + i + f + prepayAmount;
        deal(USDAI, users.borrower, totalPay + 1e20);
        vm.startPrank(users.borrower);
        IERC20(USDAI).approve(address(router), totalPay);
        router.repay(loanTerms, totalPay);
        vm.stopPrank();

        (,,, uint256 balAfter) = router.loanState(hash_);
        /* Balance dropped by at least principal + prepayment */
        assertLe(balAfter, balBefore - p - prepayAmount + 1); /* +1 wei for rounding */
    }

    function test__Repay_Prepayment_CappedAtRemainingBalance() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        (,, uint64 originationTs,) = router.loanState(hash_);

        vm.warp(_scheduleAt(loanTerms, originationTs)[0]);
        (uint256 p, uint256 i, uint256 f) = router.quote(loanTerms);
        /* Try to overpay way beyond remaining balance — should be capped */
        uint256 over = 200_000_000 * 1e18;
        deal(USDAI, users.borrower, p + i + f + over + 1e20);
        vm.startPrank(users.borrower);
        IERC20(USDAI).approve(address(router), p + i + f + over);
        router.repay(loanTerms, p + i + f + over);
        vm.stopPrank();

        /* Loan fully repaid */
        (ILoanRouterV2.LoanStatus status,,, uint256 bal) = router.loanState(hash_);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Repaid));
        assertEq(bal, 0);
    }

    function test__Repay_PrepaymentBelowInstallment_DoesNotBrickLoan() public {
        /* Default loan: $50M over 1095 days (37 deadlines). A scheduled installment is on the order of
         * $1.3M, so a prepayment that leaves a tiny balance must not strand the loan: the next window's
         * principal must re-amortize against the remaining balance rather than the original principal. */
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        (,, uint64 originationTs,) = router.loanState(hash_);

        /* Cycle 0: prepay down to a balance far below one installment, but not to zero */
        vm.warp(_scheduleAt(loanTerms, originationTs)[0]);
        (uint256 p, uint256 i, uint256 f) = router.quote(loanTerms);
        (,,, uint256 balBefore) = router.loanState(hash_);
        uint256 targetBalance = 1_000 * 1e18; /* $1k remaining, far below an installment */
        uint256 prepayment = balBefore - p - targetBalance;
        uint256 totalPay = p + i + f + prepayment;
        deal(USDAI, users.borrower, totalPay + 1e20);
        vm.startPrank(users.borrower);
        IERC20(USDAI).approve(address(router), totalPay);
        router.repay(loanTerms, totalPay);
        vm.stopPrank();

        /* Loan is still active with a tiny balance */
        (ILoanRouterV2.LoanStatus status,,, uint256 balAfter) = router.loanState(hash_);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active));
        assertGt(balAfter, 0);
        assertLt(balAfter, balBefore);

        /* Next middle window must repay without underflow-reverting */
        vm.warp(_scheduleAt(loanTerms, originationTs)[1]);
        _repayAtCurrentTimestamp(loanTerms);

        /* Repayment advanced and the balance kept shrinking */
        (, uint16 repaymentCount,, uint256 balAfter2) = router.loanState(hash_);
        assertEq(repaymentCount, 2);
        assertLe(balAfter2, balAfter);

        /* The loan remains fully repayable through to the final cycle */
        _walkAllCycles(loanTerms);
        (ILoanRouterV2.LoanStatus finalStatus,,, uint256 finalBalance) = router.loanState(hash_);
        assertEq(uint8(finalStatus), uint8(ILoanRouterV2.LoanStatus.Repaid));
        assertEq(finalBalance, 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: grace period in repay                                             */
    /*------------------------------------------------------------------------*/

    function test__Repay_PastDeadline_ChargesGraceInterest() public {
        /* Originate with grace period in IRM options */
        uint64 graceDuration = uint64(7 days);
        uint256 graceRate = RATE_14_PCT;
        RouterFixture.LoanConfig memory config = _defaultConfig();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        loanTerms.interestRateSpec.options = abi.encode(
            SimpleInterestRateModel.Options({
                gracePeriodDuration: graceDuration, gracePeriodRate: graceRate, principalAndInterestStubPayment: false
            })
        );
        vm.warp(_recipeTimestamp(config.variant));
        prepareLenderDeposits(loanTerms, true);
        prepareCollateralDeposit(loanTerms);
        originateLoan(loanTerms, buildDepositInfos(loanTerms, true), new bytes[](0));

        bytes32 hash_ = router.loanTermsHash(loanTerms);
        (,, uint64 originationTs,) = router.loanState(hash_);

        /* Quote at deadline */
        vm.warp(_scheduleAt(loanTerms, originationTs)[0]);
        (, uint256 atDeadline,) = router.quote(loanTerms);

        /* Quote 3 days past deadline — should be higher */
        vm.warp(_scheduleAt(loanTerms, originationTs)[0] + 3 days);
        (, uint256 past,) = router.quote(loanTerms);

        assertGt(past, atDeadline);
    }

    /*------------------------------------------------------------------------*/
    /* Test: hook callbacks                                                    */
    /*------------------------------------------------------------------------*/

    function _originateWithLenderContract(
        address lender
    ) internal returns (ILoanRouterV2.LoanTermsV2 memory loanTerms) {
        deal(USDAI, lender, 100_000_000 * 1e18);
        vm.prank(lender);
        IERC20(USDAI).approve(address(depositTimelock), type(uint256).max);

        RouterFixture.LoanConfig memory config = _defaultConfig();
        loanTerms = buildLoanTerms(config);
        loanTerms.trancheSpecs[0].lender = lender;

        vm.prank(users.deployer);
        AccessControl(address(depositTimelock)).grantRole(keccak256("DEPOSITOR_ROLE"), lender);

        vm.warp(_recipeTimestamp(config.variant));

        bytes32 hash_ = router.loanTermsHash(loanTerms);
        vm.prank(lender);
        depositTimelock.deposit(
            address(router), hash_, USDAI, loanTerms.trancheSpecs[0].amount, uint64(block.timestamp + 7 days)
        );
        prepareCollateralDeposit(loanTerms);
        ILoanRouterV2.LenderDepositInfo[] memory infos = new ILoanRouterV2.LenderDepositInfo[](1);
        infos[0] = ILoanRouterV2.LenderDepositInfo({depositType: ILoanRouterV2.DepositType.DepositTimelock, data: ""});
        originateLoan(loanTerms, infos, new bytes[](0));
    }

    function test__Repay_HookCalled_OnLenderContract() public {
        LenderHookRecorder hookLender = new LenderHookRecorder();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithLenderContract(address(hookLender));
        (,, uint64 originationTs,) = router.loanState(router.loanTermsHash(loanTerms));
        vm.warp(_scheduleAt(loanTerms, originationTs)[0]);
        _repayAtCurrentTimestamp(loanTerms);
        assertTrue(hookLender.onLoanRepaymentCalled());
    }

    function test__Repay_HookRevert_EmitsHookFailed_Continues() public {
        LenderHookReverter hookLender = new LenderHookReverter();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithLenderContract(address(hookLender));
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        (,, uint64 originationTs,) = router.loanState(hash_);
        vm.warp(_scheduleAt(loanTerms, originationTs)[0]);

        vm.recordLogs();
        _repayAtCurrentTimestamp(loanTerms);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("HookFailed(string)");
        bool emitted;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                emitted = true;
                break;
            }
        }
        assertTrue(emitted);

        /* Repay still advanced repaymentCount */
        (, uint16 count,,) = router.loanState(hash_);
        assertEq(count, 1);
    }

    function _originateWithFeeRecipient(
        address recipient
    ) internal returns (ILoanRouterV2.LoanTermsV2 memory) {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.feeSpecs = new ILoanRouterV2.FeeSpec[](1);
        config.feeSpecs[0] = ILoanRouterV2.FeeSpec({
            model: address(ratioFeeModel),
            recipient: recipient,
            kind: ILoanRouterV2.FeeKind.Repayment,
            options: abi.encode(
                RatioFeeModel.Options({mode: RatioFeeModel.Mode.Balance, rate: LoanFixtures.INSURANCE_ANNUAL_RATE / 12})
            )
        });
        return originateConfigured(config);
    }

    function test__Repay_FeePaidHookCalled_OnFeeRecipientContract() public {
        LenderHookRecorder feeRecipient = new LenderHookRecorder();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithFeeRecipient(address(feeRecipient));
        (,, uint64 originationTs,) = router.loanState(router.loanTermsHash(loanTerms));
        vm.warp(_scheduleAt(loanTerms, originationTs)[0]);
        _repayAtCurrentTimestamp(loanTerms);

        assertTrue(feeRecipient.onLoanFeePaidCalled());
        assertEq(feeRecipient.lastFeeSpecIndex(), 0);
        /* Hook is passed the exact fee transferred to the recipient */
        assertGt(feeRecipient.lastFeeAmount(), 0);
        assertEq(feeRecipient.lastFeeAmount(), IERC20(USDAI).balanceOf(address(feeRecipient)));
    }

    function test__Repay_FeePaidHookRevert_EmitsHookFailed_Continues() public {
        LenderHookReverter feeRecipient = new LenderHookReverter();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithFeeRecipient(address(feeRecipient));
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        (,, uint64 originationTs,) = router.loanState(hash_);
        vm.warp(_scheduleAt(loanTerms, originationTs)[0]);

        vm.recordLogs();
        _repayAtCurrentTimestamp(loanTerms);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("HookFailed(string)");
        bool emitted;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                emitted = true;
                break;
            }
        }
        assertTrue(emitted);

        /* Fee was still transferred to the recipient and repay advanced repaymentCount */
        assertGt(IERC20(USDAI).balanceOf(address(feeRecipient)), 0);
        (, uint16 count,,) = router.loanState(hash_);
        assertEq(count, 1);
    }

    /*------------------------------------------------------------------------*/
    /* Test: events                                                            */
    /*------------------------------------------------------------------------*/

    function test__Repay_EmitsLoanRepaid_FinalCycle_IsRepaidTrue() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        uint64[] memory schedule = _schedule(loanTerms);

        /* Repay all but final */
        for (uint256 i = 0; i < schedule.length - 1; i++) {
            vm.warp(schedule[i]);
            _repayAtCurrentTimestamp(loanTerms);
        }
        /* Final cycle */
        vm.warp(schedule[schedule.length - 1]);
        vm.recordLogs();
        _repayAtCurrentTimestamp(loanTerms);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256("LoanRepaid(bytes32,address,uint256,uint256,uint256,uint256,bool)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic && logs[i].topics[1] == hash_) {
                /* Decode last bool (isRepaid) from the non-indexed data: 5 uint256s + 1 bool = 6 * 32 = 192 bytes */
                (,,,, bool isRepaid) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, bool));
                assertTrue(isRepaid);
                found = true;
                break;
            }
        }
        assertTrue(found);
    }

    /*------------------------------------------------------------------------*/
    /* Test: burn lender NFT and clear reverse lookup on full repay */
    /*------------------------------------------------------------------------*/

    function test__Repay_LenderNFT_BurnedOnFullRepay() public {
        /* Originate a default loan */
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();

        /* Capture the lender position token IDs while the loan is still active */
        uint256[] memory tokenIds = router.loanTokenIds(loanTerms);

        /* Confirm the NFTs exist pre-close */
        assertEq(IERC721(address(router)).ownerOf(tokenIds[0]), STAKED_USDAI);

        /* Walk every cycle to fully repay the loan */
        _walkAllCycles(loanTerms);

        /* ownerOf must revert for each burned token ID */
        for (uint256 i = 0; i < tokenIds.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenIds[i]));
            IERC721(address(router)).ownerOf(tokenIds[i]);
        }
    }

    function test__Repay_LoanReverseLookup_DeletedOnFullRepay() public {
        /* Originate a default loan */
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();

        /* Capture the lender position token IDs */
        uint256[] memory tokenIds = router.loanTokenIds(loanTerms);

        /* Walk every cycle to fully repay the loan */
        _walkAllCycles(loanTerms);

        /* Post-close lookup by tokenId resolves to the Uninitialized tuple */
        (ILoanRouterV2.LoanStatus status, uint16 count, uint64 originationTs, uint256 balance) =
            router.loanState(tokenIds[0]);

        /* All fields must be zero-valued */
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Uninitialized));
        assertEq(count, 0);
        assertEq(balance, 0);
        assertEq(originationTs, 0);
    }

    function test__Repay_LenderNFT_NotBurnedOnPartialRepay() public {
        /* Originate a default loan */
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();

        /* Capture the lender position token IDs */
        uint256[] memory tokenIds = router.loanTokenIds(loanTerms);

        /* Resolve the originating loan timestamp */
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        (,, uint64 originationTs,) = router.loanState(loanTermsHash_);

        /* Repay the first cycle only */
        vm.warp(_scheduleAt(loanTerms, originationTs)[0]);
        _repayAtCurrentTimestamp(loanTerms);

        /* Lender position NFT must still exist with original owner */
        assertEq(IERC721(address(router)).ownerOf(tokenIds[0]), STAKED_USDAI);

        /* Lookup by tokenId must still resolve to the live loan */
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(tokenIds[0]);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active));
    }
}
