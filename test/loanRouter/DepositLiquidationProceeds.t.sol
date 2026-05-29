// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Vm} from "forge-std/Vm.sol";

import {RouterFixture} from "../helpers/RouterFixture.sol";
import {LenderHookRecorder} from "../mocks/LenderHookRecorder.sol";
import {LenderHookReverter} from "../mocks/LenderHookReverter.sol";

import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {RatioFeeModel} from "src/fees/RatioFeeModel.sol";
import {AbsoluteFeeModel} from "src/fees/AbsoluteFeeModel.sol";

contract LoanRouterV2DepositLiquidationProceedsTest is RouterFixture {
    /*------------------------------------------------------------------------*/
    /* Helpers */
    /*------------------------------------------------------------------------*/

    function _liquidatedTwoTrancheLoan() internal returns (ILoanRouterV2.LoanTermsV2 memory loanTerms) {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.twoTranches = true;
        config.useEscrowTimelock = false;
        loanTerms = originateConfigured(config);
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);

        vm.prank(users.liquidator);
        router.setLoanBreach(loanTermsHash_);
        vm.prank(users.liquidator);
        router.liquidate(loanTerms);
    }

    function _depositProceeds(
        ILoanRouterV2.LoanTermsV2 memory loanTerms,
        uint256 proceeds
    ) internal {
        deal(loanTerms.currencyToken, users.liquidator, proceeds);
        vm.startPrank(users.liquidator);
        IERC20(loanTerms.currencyToken).approve(address(router), proceeds);
        router.depositLiquidationProceeds(loanTerms, proceeds);
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: sub-par waterfall (senior-first by tranche array index) */
    /*------------------------------------------------------------------------*/

    function test__DepositLiquidationProceeds_SubPar_SeniorPaidFullPrincipal_JuniorShortfall() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _liquidatedTwoTrancheLoan();

        uint256 lender1Before = IERC20(USDAI).balanceOf(users.lender1);
        uint256 lender2Before = IERC20(USDAI).balanceOf(users.lender2);

        /* $30M proceeds for ~$50M+ outstanding. Pro-rata tranche principals are $25M each. */
        _depositProceeds(loanTerms, 30_000_000 * 1e18);

        uint256 lender1Gained = IERC20(USDAI).balanceOf(users.lender1) - lender1Before;
        uint256 lender2Gained = IERC20(USDAI).balanceOf(users.lender2) - lender2Before;

        /* Senior (trancheSpecs[0] = lender1) fully paid pro-rata principal */
        assertEq(lender1Gained, 25_000_000 * 1e18);
        /* Junior gets the remaining $5M */
        assertEq(lender2Gained, 5_000_000 * 1e18);
    }

    function test__DepositLiquidationProceeds_SubPar_JuniorGetsZeroWhenProceedsBelowSeniorShare() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _liquidatedTwoTrancheLoan();

        uint256 lender1Before = IERC20(USDAI).balanceOf(users.lender1);
        uint256 lender2Before = IERC20(USDAI).balanceOf(users.lender2);

        /* $20M proceeds: less than senior's $25M pro-rata principal */
        _depositProceeds(loanTerms, 20_000_000 * 1e18);

        uint256 lender1Gained = IERC20(USDAI).balanceOf(users.lender1) - lender1Before;
        uint256 lender2Gained = IERC20(USDAI).balanceOf(users.lender2) - lender2Before;

        /* Senior gets all $20M; junior gets nothing */
        assertEq(lender1Gained, 20_000_000 * 1e18);
        assertEq(lender2Gained, 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: at-par waterfall */
    /*------------------------------------------------------------------------*/

    function test__DepositLiquidationProceeds_AtPar_BothTranchesFullyPaidPrincipal() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _liquidatedTwoTrancheLoan();

        uint256 lender1Before = IERC20(USDAI).balanceOf(users.lender1);
        uint256 lender2Before = IERC20(USDAI).balanceOf(users.lender2);

        /* Deposit exactly $50M — enough to cover principals (interest still owed but not paid) */
        _depositProceeds(loanTerms, 50_000_000 * 1e18);

        uint256 lender1Gained = IERC20(USDAI).balanceOf(users.lender1) - lender1Before;
        uint256 lender2Gained = IERC20(USDAI).balanceOf(users.lender2) - lender2Before;

        /* Both tranches receive their full $25M principal; interest paid 0 since proceeds exactly covered principal */
        assertEq(lender1Gained, 25_000_000 * 1e18);
        assertEq(lender2Gained, 25_000_000 * 1e18);
    }

    /*------------------------------------------------------------------------*/
    /* Test: excess waterfall */
    /*------------------------------------------------------------------------*/

    function test__DepositLiquidationProceeds_Excess_BothTranchesFullyPaid_SurplusToFeeRecipient() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _liquidatedTwoTrancheLoan();

        uint256 lender1Before = IERC20(USDAI).balanceOf(users.lender1);
        uint256 lender2Before = IERC20(USDAI).balanceOf(users.lender2);
        uint256 feeRecipientBefore = IERC20(USDAI).balanceOf(users.feeRecipient);

        /* Deposit way more than principal + any plausible window interest — $60M */
        uint256 proceeds = 60_000_000 * 1e18;
        _depositProceeds(loanTerms, proceeds);

        uint256 lender1Gained = IERC20(USDAI).balanceOf(users.lender1) - lender1Before;
        uint256 lender2Gained = IERC20(USDAI).balanceOf(users.lender2) - lender2Before;
        uint256 feeRecipientGained = IERC20(USDAI).balanceOf(users.feeRecipient) - feeRecipientBefore;

        /* Both lenders get their $25M plus their interest share */
        assertGe(lender1Gained, 25_000_000 * 1e18);
        assertGe(lender2Gained, 25_000_000 * 1e18);

        /* Surplus to fee recipient: proceeds - paid_principal - paid_interest */
        assertEq(lender1Gained + lender2Gained + feeRecipientGained, proceeds);
        assertGt(feeRecipientGained, 0);
    }

    function test__DepositLiquidationProceeds_Excess_LenderInterestPaid() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _liquidatedTwoTrancheLoan();

        uint256 lender1Before = IERC20(USDAI).balanceOf(users.lender1);
        uint256 lender2Before = IERC20(USDAI).balanceOf(users.lender2);

        _depositProceeds(loanTerms, 60_000_000 * 1e18);

        uint256 lender1Gained = IERC20(USDAI).balanceOf(users.lender1) - lender1Before;
        uint256 lender2Gained = IERC20(USDAI).balanceOf(users.lender2) - lender2Before;

        /* Junior (9% rate) earns slightly more interest than senior (8% rate) for the same time window */
        assertGt(lender2Gained, lender1Gained);
    }

    /*------------------------------------------------------------------------*/
    /* Test: single-tranche control */
    /*------------------------------------------------------------------------*/

    function test__DepositLiquidationProceeds_SingleTranche_AtPar() public {
        /* DepositTimelock single-tranche so we can assert lender1's balance directly */
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.useEscrowTimelock = false;
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateConfigured(config);
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        vm.prank(users.liquidator);
        router.setLoanBreach(loanTermsHash_);
        vm.prank(users.liquidator);
        router.liquidate(loanTerms);

        uint256 lender1Before = IERC20(USDAI).balanceOf(users.lender1);
        _depositProceeds(loanTerms, 50_000_000 * 1e18);

        /* Single tranche, $50M proceeds → lender1 gets the full $50M */
        assertEq(IERC20(USDAI).balanceOf(users.lender1) - lender1Before, 50_000_000 * 1e18);
    }

    /*------------------------------------------------------------------------*/
    /* Test: status transition */
    /*------------------------------------------------------------------------*/

    function test__DepositLiquidationProceeds_FlipsStatusToCollateralLiquidated() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _liquidatedTwoTrancheLoan();
        _depositProceeds(loanTerms, 50_000_000 * 1e18);
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(router.loanTermsHash(loanTerms));
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.CollateralLiquidated));
    }

    /*------------------------------------------------------------------------*/
    /* Test: revert paths */
    /*------------------------------------------------------------------------*/

    function test__DepositLiquidationProceeds_RevertWhen_NotLiquidator() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _liquidatedTwoTrancheLoan();
        deal(USDAI, users.borrower, 1e18);
        vm.startPrank(users.borrower);
        IERC20(USDAI).approve(address(router), 1e18);
        vm.expectRevert();
        router.depositLiquidationProceeds(loanTerms, 1e18);
        vm.stopPrank();
    }

    function test__DepositLiquidationProceeds_RevertWhen_NotLiquidatedStatus() public {
        /* Originate but don't liquidate */
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.twoTranches = true;
        config.useEscrowTimelock = false;
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateConfigured(config);

        deal(USDAI, users.liquidator, 1e18);
        vm.startPrank(users.liquidator);
        IERC20(USDAI).approve(address(router), 1e18);
        vm.expectRevert(ILoanRouterV2.InvalidLoanState.selector);
        router.depositLiquidationProceeds(loanTerms, 1e18);
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: boundary values                                                   */
    /*------------------------------------------------------------------------*/

    function test__DepositLiquidationProceeds_ProceedsZero_NoPayoutsNoSurplus() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _liquidatedTwoTrancheLoan();
        uint256 lender1Before = IERC20(USDAI).balanceOf(users.lender1);
        uint256 lender2Before = IERC20(USDAI).balanceOf(users.lender2);
        uint256 feeRecipientBefore = IERC20(USDAI).balanceOf(users.feeRecipient);

        _depositProceeds(loanTerms, 0);

        assertEq(IERC20(USDAI).balanceOf(users.lender1), lender1Before);
        assertEq(IERC20(USDAI).balanceOf(users.lender2), lender2Before);
        assertEq(IERC20(USDAI).balanceOf(users.feeRecipient), feeRecipientBefore);
    }

    function test__DepositLiquidationProceeds_ProceedsExactlySeniorPrincipal() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _liquidatedTwoTrancheLoan();
        uint256 lender1Before = IERC20(USDAI).balanceOf(users.lender1);
        uint256 lender2Before = IERC20(USDAI).balanceOf(users.lender2);

        _depositProceeds(loanTerms, 25_000_000 * 1e18); /* exactly senior principal */

        assertEq(IERC20(USDAI).balanceOf(users.lender1) - lender1Before, 25_000_000 * 1e18);
        assertEq(IERC20(USDAI).balanceOf(users.lender2) - lender2Before, 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: liquidation fee path                                              */
    /*------------------------------------------------------------------------*/

    function _originateWithLiquidationFee(
        ILoanRouterV2.FeeSpec memory feeSpec
    ) internal returns (ILoanRouterV2.LoanTermsV2 memory loanTerms) {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.twoTranches = true;
        config.useEscrowTimelock = false;
        config.feeSpecs = new ILoanRouterV2.FeeSpec[](1);
        config.feeSpecs[0] = feeSpec;
        loanTerms = originateConfigured(config);
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        vm.prank(users.liquidator);
        router.setLoanBreach(hash_);
        vm.prank(users.liquidator);
        router.liquidate(loanTerms);
    }

    function test__DepositLiquidationProceeds_WithPercentageLiquidationFee_DeductedBeforeWaterfall() public {
        /* 2% liquidation fee on proceeds */
        ILoanRouterV2.FeeSpec memory feeSpec = ILoanRouterV2.FeeSpec({
            model: address(ratioFeeModel),
            recipient: insuranceRecipient,
            kind: ILoanRouterV2.FeeKind.Liquidation,
            options: abi.encode(RatioFeeModel.Options({mode: RatioFeeModel.Mode.Amount, rate: 0.02e18}))
        });
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithLiquidationFee(feeSpec);
        uint256 recipientBefore = IERC20(USDAI).balanceOf(insuranceRecipient);
        /* Deposit excess proceeds */
        _depositProceeds(loanTerms, 60_000_000 * 1e18);
        /* Fee recipient gained exactly 2% of $60M proceeds = $1.2M */
        assertEq(IERC20(USDAI).balanceOf(insuranceRecipient) - recipientBefore, 1_200_000 * 1e18);
    }

    function test__DepositLiquidationProceeds_WithAbsoluteLiquidationFee_FixedAmount() public {
        ILoanRouterV2.FeeSpec memory feeSpec = ILoanRouterV2.FeeSpec({
            model: address(absoluteFeeModel),
            recipient: insuranceRecipient,
            kind: ILoanRouterV2.FeeKind.Liquidation,
            options: abi.encode(AbsoluteFeeModel.Options({amount: 500_000 * 1e18}))
        });
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithLiquidationFee(feeSpec);
        uint256 recipientBefore = IERC20(USDAI).balanceOf(insuranceRecipient);
        _depositProceeds(loanTerms, 60_000_000 * 1e18);
        assertEq(IERC20(USDAI).balanceOf(insuranceRecipient) - recipientBefore, 500_000 * 1e18);
    }

    function test__DepositLiquidationProceeds_LiquidationFeeRecipientZero_FallsBackToDefault() public {
        ILoanRouterV2.FeeSpec memory feeSpec = ILoanRouterV2.FeeSpec({
            model: address(ratioFeeModel),
            recipient: address(0), /* fallback to default fee recipient */
            kind: ILoanRouterV2.FeeKind.Liquidation,
            options: abi.encode(RatioFeeModel.Options({mode: RatioFeeModel.Mode.Amount, rate: 0.01e18}))
        });
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithLiquidationFee(feeSpec);
        uint256 defaultBefore = IERC20(USDAI).balanceOf(users.feeRecipient);
        _depositProceeds(loanTerms, 60_000_000 * 1e18);
        /* Default fee recipient gets the fee (1% of $60M proceeds = $600k) AND the surplus */
        assertGt(IERC20(USDAI).balanceOf(users.feeRecipient) - defaultBefore, 600_000 * 1e18);
    }

    function test__DepositLiquidationProceeds_EmitsFeePaid_ForLiquidationFee() public {
        ILoanRouterV2.FeeSpec memory feeSpec = ILoanRouterV2.FeeSpec({
            model: address(ratioFeeModel),
            recipient: insuranceRecipient,
            kind: ILoanRouterV2.FeeKind.Liquidation,
            options: abi.encode(RatioFeeModel.Options({mode: RatioFeeModel.Mode.Amount, rate: 0.02e18}))
        });
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithLiquidationFee(feeSpec);
        bytes32 hash_ = router.loanTermsHash(loanTerms);

        uint256 proceeds = 60_000_000 * 1e18;
        deal(USDAI, users.liquidator, proceeds);
        vm.startPrank(users.liquidator);
        IERC20(USDAI).approve(address(router), proceeds);
        vm.expectEmit(true, true, true, true, address(router));
        emit ILoanRouterV2.FeePaid(
            hash_, ILoanRouterV2.FeeKind.Liquidation, insuranceRecipient, address(ratioFeeModel), 1_200_000 * 1e18
        );
        router.depositLiquidationProceeds(loanTerms, proceeds);
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: hook callbacks                                                    */
    /*------------------------------------------------------------------------*/

    function _liquidatedTwoTrancheLoan_WithContractLender(
        address contractLender
    ) internal returns (ILoanRouterV2.LoanTermsV2 memory loanTerms) {
        /* Fund the contract lender and approve depositTimelock */
        deal(USDAI, contractLender, 100_000_000 * 1e18);
        vm.prank(contractLender);
        IERC20(USDAI).approve(address(depositTimelock), type(uint256).max);

        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.twoTranches = true;
        config.useEscrowTimelock = false;
        loanTerms = buildLoanTerms(config);
        loanTerms.trancheSpecs[1].lender = contractLender;

        vm.startPrank(users.deployer);
        AccessControl(address(depositTimelock)).grantRole(keccak256("DEPOSITOR_ROLE"), contractLender);
        vm.stopPrank();

        vm.warp(_recipeTimestamp(config.variant));
        bytes32 hash_ = router.loanTermsHash(loanTerms);

        /* Tranche 0 = users.lender1 (DepositTimelock); Tranche 1 = contractLender (DepositTimelock) */
        vm.prank(users.lender1);
        depositTimelock.deposit(
            address(router), hash_, USDAI, loanTerms.trancheSpecs[0].amount, uint64(block.timestamp + 7 days)
        );
        vm.prank(contractLender);
        depositTimelock.deposit(
            address(router), hash_, USDAI, loanTerms.trancheSpecs[1].amount, uint64(block.timestamp + 7 days)
        );

        prepareCollateralDeposit(loanTerms);
        ILoanRouterV2.LenderDepositInfo[] memory infos = new ILoanRouterV2.LenderDepositInfo[](2);
        infos[0] = ILoanRouterV2.LenderDepositInfo({depositType: ILoanRouterV2.DepositType.DepositTimelock, data: ""});
        infos[1] = ILoanRouterV2.LenderDepositInfo({depositType: ILoanRouterV2.DepositType.DepositTimelock, data: ""});
        originateLoan(loanTerms, infos, new bytes[](0));

        vm.prank(users.liquidator);
        router.setLoanBreach(hash_);
        vm.prank(users.liquidator);
        router.liquidate(loanTerms);
    }

    function test__DepositLiquidationProceeds_HookCalled_OnLiquidationProceedsDeposited() public {
        LenderHookRecorder hookLender = new LenderHookRecorder();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _liquidatedTwoTrancheLoan_WithContractLender(address(hookLender));
        _depositProceeds(loanTerms, 60_000_000 * 1e18);
        assertTrue(hookLender.onLiquidationProceedsDepositedCalled());
    }

    function test__DepositLiquidationProceeds_HookRevert_EmitsHookFailed_Continues() public {
        LenderHookReverter hookLender = new LenderHookReverter();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _liquidatedTwoTrancheLoan_WithContractLender(address(hookLender));

        vm.recordLogs();
        _depositProceeds(loanTerms, 60_000_000 * 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 hookFailedTopic = keccak256("HookFailed(string)");
        bool emitted;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == hookFailedTopic) {
                emitted = true;
                break;
            }
        }
        assertTrue(emitted);

        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(router.loanTermsHash(loanTerms));
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.CollateralLiquidated));
    }

    /*------------------------------------------------------------------------*/
    /* Test: events                                                            */
    /*------------------------------------------------------------------------*/

    function test__DepositLiquidationProceeds_EmitsLiquidationProceedsDeposited_WithSurplus() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _liquidatedTwoTrancheLoan();
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        uint256 proceeds = 60_000_000 * 1e18;
        deal(USDAI, users.liquidator, proceeds);
        vm.startPrank(users.liquidator);
        IERC20(USDAI).approve(address(router), proceeds);
        /* We only assert the topic-0 of the event; amount math depends on IRM interest */
        vm.expectEmit(true, false, false, false, address(router));
        emit ILoanRouterV2.LiquidationProceedsDeposited(hash_, proceeds, 0, 0);
        router.depositLiquidationProceeds(loanTerms, proceeds);
        vm.stopPrank();
    }

    function test__DepositLiquidationProceeds_EmitsLenderLiquidationRepaid_PerTranche() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _liquidatedTwoTrancheLoan();
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        uint256 proceeds = 60_000_000 * 1e18;
        deal(USDAI, users.liquidator, proceeds);
        vm.startPrank(users.liquidator);
        IERC20(USDAI).approve(address(router), proceeds);

        vm.recordLogs();
        router.depositLiquidationProceeds(loanTerms, proceeds);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("LenderLiquidationRepaid(bytes32,address,uint8,uint256,uint256)");
        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                if (logs[i].topics[1] == hash_) count++;
            }
        }
        assertEq(count, 2);
    }

    /*------------------------------------------------------------------------*/
    /* Test: re-deposit                                                        */
    /*------------------------------------------------------------------------*/

    function test__DepositLiquidationProceeds_RevertWhen_AlreadyCollateralLiquidated() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _liquidatedTwoTrancheLoan();
        _depositProceeds(loanTerms, 50_000_000 * 1e18);
        /* Status is now CollateralLiquidated; second deposit reverts */
        deal(USDAI, users.liquidator, 1e18);
        vm.startPrank(users.liquidator);
        IERC20(USDAI).approve(address(router), 1e18);
        vm.expectRevert(ILoanRouterV2.InvalidLoanState.selector);
        router.depositLiquidationProceeds(loanTerms, 1e18);
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: status matrix - extended                                          */
    /*------------------------------------------------------------------------*/

    function test__DepositLiquidationProceeds_RevertWhen_StatusBreached() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.twoTranches = true;
        config.useEscrowTimelock = false;
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateConfigured(config);
        bytes32 hash_ = router.loanTermsHash(loanTerms);

        vm.prank(users.liquidator);
        router.setLoanBreach(hash_); /* status = Breached, not Liquidated */

        deal(USDAI, users.liquidator, 1e18);
        vm.startPrank(users.liquidator);
        IERC20(USDAI).approve(address(router), 1e18);
        vm.expectRevert(ILoanRouterV2.InvalidLoanState.selector);
        router.depositLiquidationProceeds(loanTerms, 1e18);
        vm.stopPrank();
    }

    function test__DepositLiquidationProceeds_RevertWhen_StatusUninitialized() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        deal(USDAI, users.liquidator, 1e18);
        vm.startPrank(users.liquidator);
        IERC20(USDAI).approve(address(router), 1e18);
        vm.expectRevert(ILoanRouterV2.InvalidLoanState.selector);
        router.depositLiquidationProceeds(loanTerms, 1e18);
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: lender NFTs burned and reverse lookup cleared on close */
    /*------------------------------------------------------------------------*/

    function test__DepositLiquidationProceeds_LenderNFTs_BurnedAndLookupCleared() public {
        /* Build a two-tranche loan and drive it to the Liquidated state */
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _liquidatedTwoTrancheLoan();

        /* Capture lender position token IDs before the burn */
        uint256[] memory tokenIds = router.loanTokenIds(loanTerms);

        /* Deposit at-par proceeds, which runs the burn loop */
        _depositProceeds(loanTerms, 50_000_000 * 1e18);

        /* Each lender NFT must now revert ownerOf as a nonexistent token */
        for (uint256 i = 0; i < tokenIds.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenIds[i]));
            IERC721(address(router)).ownerOf(tokenIds[i]);
        }

        /* loanState(tokenId) must resolve to the Uninitialized tuple after the lookup is deleted */
        (ILoanRouterV2.LoanStatus status, uint16 count, uint64 originationTs, uint256 balance) =
            router.loanState(tokenIds[0]);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Uninitialized));
        assertEq(count, 0);
        assertEq(balance, 0);
        assertEq(originationTs, 0);
    }
}
