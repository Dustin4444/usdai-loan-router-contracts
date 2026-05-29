// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20 as IERC20Like} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {RouterFixture} from "../helpers/RouterFixture.sol";
import {LoanFixtures} from "../helpers/LoanFixtures.sol";

import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {RatioFeeModel} from "src/fees/RatioFeeModel.sol";
import {AbsoluteFeeModel} from "src/fees/AbsoluteFeeModel.sol";
import {SimpleInterestRateModel} from "src/rates/SimpleInterestRateModel.sol";

contract LoanRouterV2QuoteTest is RouterFixture {
    /*------------------------------------------------------------------------*/
    /* Test: both overloads agree */
    /*------------------------------------------------------------------------*/

    function test__Quote_BothOverloads_AgreeAtCurrentTimestamp() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        (,, uint64 originationTs,) = router.loanState(router.loanTermsHash(loanTerms));
        vm.warp(_scheduleAt(loanTerms, originationTs)[0]);
        (uint256 p1, uint256 i1, uint256 f1) = router.quote(loanTerms);
        (uint256 p2, uint256 i2, uint256 f2) = router.quote(loanTerms, uint64(block.timestamp));
        assertEq(p1, p2);
        assertEq(i1, i2);
        assertEq(f1, f2);
    }

    /*------------------------------------------------------------------------*/
    /* Test: quote returns zeros for uninitialized loans */
    /*------------------------------------------------------------------------*/

    function test__Quote_LoanNotActive_ReturnsZeros() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        (uint256 p, uint256 i, uint256 f) = router.quote(loanTerms);
        assertEq(p, 0);
        assertEq(i, 0);
        assertEq(f, 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: per-cycle quote advances correctly (37-deadline schedule) */
    /*------------------------------------------------------------------------*/

    function test__Quote_StubCycleInterestOnly_ThenPrincipal() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        (,, uint64 originationTs,) = router.loanState(loanTermsHash_);
        uint64[] memory schedule = _scheduleAt(loanTerms, originationTs);

        /* Cycle 0 is a stub (off-anchor origination): interest only, no principal, no fee specs */
        vm.warp(schedule[0]);
        (uint256 p0, uint256 i0, uint256 f0) = router.quote(loanTerms);
        assertEq(p0, 0);
        assertGt(i0, 0);
        assertEq(f0, 0);

        /* After repaying the stub, the next cycle pays both principal and interest */
        _repayAt(loanTerms, schedule[0]);
        vm.warp(schedule[1]);
        (uint256 p1, uint256 i1,) = router.quote(loanTerms);
        assertGt(p1, 0);
        assertGt(i1, 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: insurance fee shows up in quote */
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

    function test__Quote_PercentageInsurance_Cycle0_HasExpectedAmount() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithPercentageInsurance();
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        (,, uint64 originationTs, uint256 scaledBalance) = router.loanState(loanTermsHash_);
        uint64 firstDeadline = _scheduleAt(loanTerms, originationTs)[0];
        vm.warp(firstDeadline);
        (,, uint256 feePayment) = router.quote(loanTerms);

        /* Sanity: default config originates at LOAN_AMOUNT_USDAI in 18dp units. */
        assertEq(scaledBalance, LOAN_AMOUNT_USDAI);

        /* RatioFeeModel.Balance: rate applied flat to balance, no time proration. */
        uint256 expectedFee =
            Math.mulDiv(LOAN_AMOUNT_USDAI, LoanFixtures.INSURANCE_ANNUAL_RATE / 12, 1e18, Math.Rounding.Ceil);
        assertEq(feePayment, expectedFee);
    }

    /*------------------------------------------------------------------------*/
    /* Test: status matrix - non-Active returns zeros                          */
    /*------------------------------------------------------------------------*/

    function test__Quote_RepaidStatus_ReturnsZeros() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        uint64[] memory schedule = _schedule(loanTerms);
        for (uint256 i = 0; i < schedule.length; i++) {
            vm.warp(schedule[i]);
            (uint256 p, uint256 ii, uint256 f) = router.quote(loanTerms);
            uint256 total = p + ii + f;
            if (total == 0) continue;
            deal(USDAI, users.borrower, total + 1e20);
            vm.startPrank(users.borrower);
            IERC20Like(USDAI).approve(address(router), total);
            router.repay(loanTerms, total);
            vm.stopPrank();
        }
        (uint256 p2, uint256 i2, uint256 f2) = router.quote(loanTerms);
        assertEq(p2, 0);
        assertEq(i2, 0);
        assertEq(f2, 0);
    }

    function test__Quote_BreachedStatus_ReturnsZeros() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        vm.prank(users.liquidator);
        router.setLoanBreach(hash_);
        (uint256 p, uint256 i, uint256 f) = router.quote(loanTerms);
        assertEq(p, 0);
        assertEq(i, 0);
        assertEq(f, 0);
    }

    function test__Quote_LiquidatedStatus_ReturnsZeros() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        vm.prank(users.liquidator);
        router.setLoanBreach(hash_);
        vm.prank(users.liquidator);
        router.liquidate(loanTerms);
        (uint256 p, uint256 i, uint256 f) = router.quote(loanTerms);
        assertEq(p, 0);
        assertEq(i, 0);
        assertEq(f, 0);
    }

    function test__Quote_CollateralLiquidatedStatus_ReturnsZeros() public {
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
        IERC20Like(USDAI).approve(address(router), proceeds);
        router.depositLiquidationProceeds(loanTerms, proceeds);
        vm.stopPrank();
        (uint256 p, uint256 i, uint256 f) = router.quote(loanTerms);
        assertEq(p, 0);
        assertEq(i, 0);
        assertEq(f, 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: quote advances with cycle                                         */
    /*------------------------------------------------------------------------*/

    function test__Quote_AdvancesWithCycle_AfterRepay() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        (,, uint64 originationTs, uint256 balanceBefore) = router.loanState(hash_);
        uint64[] memory schedule = _scheduleAt(loanTerms, originationTs);

        /* Cycle 0 is an interest-only stub: the balance is unchanged after it */
        _repayAt(loanTerms, schedule[0]);
        (,,, uint256 balanceAfterStub) = router.loanState(hash_);
        assertEq(balanceAfterStub, balanceBefore);

        /* Cycle 1 quotes both principal and interest, and repaying it decreases the balance */
        vm.warp(schedule[1]);
        (uint256 p1, uint256 i1,) = router.quote(loanTerms);
        assertGt(p1, 0);
        assertGt(i1, 0);

        _repayAt(loanTerms, schedule[1]);
        (,,, uint256 balanceAfter) = router.loanState(hash_);
        assertLt(balanceAfter, balanceBefore);
    }

    /*------------------------------------------------------------------------*/
    /* Test: grace period interest                                             */
    /*------------------------------------------------------------------------*/

    function test__Quote_PastDeadline_AddsGraceInterest() public {
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

        (,, uint64 originationTs,) = router.loanState(router.loanTermsHash(loanTerms));
        vm.warp(_scheduleAt(loanTerms, originationTs)[0]);
        (, uint256 baseInt,) = router.quote(loanTerms);
        vm.warp(_scheduleAt(loanTerms, originationTs)[0] + 3 days);
        (, uint256 graceInt,) = router.quote(loanTerms);
        assertGt(graceInt, baseInt);
    }

    function test__Quote_PastGracePeriod_CappedAtGraceDuration() public {
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

        (,, uint64 originationTs,) = router.loanState(router.loanTermsHash(loanTerms));
        vm.warp(_scheduleAt(loanTerms, originationTs)[0] + graceDuration);
        (, uint256 capInt,) = router.quote(loanTerms);
        vm.warp(_scheduleAt(loanTerms, originationTs)[0] + graceDuration * 5); /* far past grace */
        (, uint256 farInt,) = router.quote(loanTerms);
        assertEq(farInt, capInt); /* capped — no further accrual past grace end */
    }

    /*------------------------------------------------------------------------*/
    /* Test: multiple repayment fee specs are summed                           */
    /*------------------------------------------------------------------------*/

    function test__Quote_MultipleRepaymentFees_Summed() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.feeSpecs = new ILoanRouterV2.FeeSpec[](2);
        config.feeSpecs[0] = ILoanRouterV2.FeeSpec({
            model: address(ratioFeeModel),
            recipient: insuranceRecipient,
            kind: ILoanRouterV2.FeeKind.Repayment,
            options: abi.encode(
                RatioFeeModel.Options({mode: RatioFeeModel.Mode.Balance, rate: LoanFixtures.INSURANCE_ANNUAL_RATE / 12})
            )
        });
        config.feeSpecs[1] = ILoanRouterV2.FeeSpec({
            model: address(absoluteFeeModel),
            recipient: insuranceRecipient,
            kind: ILoanRouterV2.FeeKind.Repayment,
            options: abi.encode(AbsoluteFeeModel.Options({amount: 1_000 * 1e18}))
        });
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateConfigured(config);
        (,, uint64 originationTs,) = router.loanState(router.loanTermsHash(loanTerms));
        vm.warp(_scheduleAt(loanTerms, originationTs)[0]);
        (,, uint256 f) = router.quote(loanTerms);
        /* Fee equals percentage fee + absolute fee. At least both components must be non-zero and the
         * total exceeds the absolute fee alone. */
        assertGt(f, 1_000 * 1e18);
    }

    /*------------------------------------------------------------------------*/
    /* Test: future timestamp                                                  */
    /*------------------------------------------------------------------------*/

    function test__Quote_FutureTimestamp_StillReturnsBreakdown() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        (,, uint64 originationTs,) = router.loanState(router.loanTermsHash(loanTerms));
        uint64[] memory schedule = _scheduleAt(loanTerms, originationTs);

        /* Clear the interest-only stub so the current window pays principal */
        _repayAt(loanTerms, schedule[0]);

        /* Quote with a timestamp several cycles ahead (still within the loan window) */
        (uint256 p, uint256 i,) = router.quote(loanTerms, schedule[5]);
        assertGt(p, 0);
        assertGt(i, 0);
    }
}
