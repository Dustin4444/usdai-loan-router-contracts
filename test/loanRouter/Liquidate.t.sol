// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20 as IERC20Like} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Vm} from "forge-std/Vm.sol";

import {RouterFixture} from "../helpers/RouterFixture.sol";
import {LoanFixtures} from "../helpers/LoanFixtures.sol";
import {LenderHookRecorder} from "../mocks/LenderHookRecorder.sol";
import {LenderHookReverter} from "../mocks/LenderHookReverter.sol";

import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {SimpleInterestRateModel} from "src/rates/SimpleInterestRateModel.sol";

contract LoanRouterV2LiquidateTest is RouterFixture {
    /*------------------------------------------------------------------------*/
    /* Helpers */
    /*------------------------------------------------------------------------*/

    function _originateWithGracePeriod(
        uint64 graceDuration
    ) internal returns (ILoanRouterV2.LoanTermsV2 memory) {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        loanTerms.interestRateSpec.options = abi.encode(
            SimpleInterestRateModel.Options({
                gracePeriodDuration: graceDuration, gracePeriodRate: RATE_14_PCT, principalAndInterestStubPayment: false
            })
        );
        vm.warp(_recipeTimestamp(config.variant));
        prepareLenderDeposits(loanTerms, true);
        prepareCollateralDeposit(loanTerms);
        originateLoan(loanTerms, buildDepositInfos(loanTerms, true), new bytes[](0));
        return loanTerms;
    }

    function _originateTwoTranches() internal returns (ILoanRouterV2.LoanTermsV2 memory) {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.twoTranches = true;
        config.useEscrowTimelock = false;
        return originateConfigured(config);
    }

    /*------------------------------------------------------------------------*/
    /* Test: liquidate after grace period */
    /*------------------------------------------------------------------------*/

    function test__Liquidate_AfterGracePeriod_TransfersCollateral() public {
        uint64 graceDuration = uint64(7 days);
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithGracePeriod(graceDuration);
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        (,, uint64 originationTs,) = router.loanState(loanTermsHash_);

        /* Warp past the grace period of the first deadline */
        vm.warp(_scheduleAt(loanTerms, originationTs)[0] + graceDuration + 1);

        vm.prank(users.liquidator);
        router.liquidate(loanTerms);

        /* Collateral transferred to liquidator */
        assertEq(collateralNft.ownerOf(loanTerms.collateralTokenIds[0]), users.liquidator);

        /* Status flipped to Liquidated */
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(loanTermsHash_);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Liquidated));
    }

    /*------------------------------------------------------------------------*/
    /* Test: liquidate after breach (immediate, no grace) */
    /*------------------------------------------------------------------------*/

    function test__Liquidate_AfterBreach_AllowedImmediately() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);

        /* Mark loan breached */
        vm.prank(users.liquidator);
        router.setLoanBreach(loanTermsHash_);

        /* Liquidate without warping past grace */
        vm.prank(users.liquidator);
        router.liquidate(loanTerms);

        assertEq(collateralNft.ownerOf(loanTerms.collateralTokenIds[0]), users.liquidator);
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(loanTermsHash_);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Liquidated));
    }

    /*------------------------------------------------------------------------*/
    /* Test: multi-tranche liquidation transfers all collateral */
    /*------------------------------------------------------------------------*/

    function test__Liquidate_TwoTranches_TransfersAllCollateral() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateTwoTranches();
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);

        vm.prank(users.liquidator);
        router.setLoanBreach(loanTermsHash_);
        vm.prank(users.liquidator);
        router.liquidate(loanTerms);

        /* Each collateral NFT transferred to liquidator (just one in our config) */
        for (uint256 i = 0; i < loanTerms.collateralTokenIds.length; i++) {
            assertEq(collateralNft.ownerOf(loanTerms.collateralTokenIds[i]), users.liquidator);
        }
    }

    /*------------------------------------------------------------------------*/
    /* Test: window variants */
    /*------------------------------------------------------------------------*/

    function test__Liquidate_1095Days_36Deadlines_AfterBreach() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.variant = LoanFixtures.WindowVariant.Lower;
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateConfigured(config);
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        vm.prank(users.liquidator);
        router.setLoanBreach(loanTermsHash_);
        vm.prank(users.liquidator);
        router.liquidate(loanTerms);
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(loanTermsHash_);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Liquidated));
    }

    function test__Liquidate_1095Days_37Deadlines_AfterBreach() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        vm.prank(users.liquidator);
        router.setLoanBreach(loanTermsHash_);
        vm.prank(users.liquidator);
        router.liquidate(loanTerms);
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(loanTermsHash_);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Liquidated));
    }

    /*------------------------------------------------------------------------*/
    /* Test: revert paths */
    /*------------------------------------------------------------------------*/

    function test__Liquidate_RevertWhen_NotLiquidator() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        vm.prank(users.borrower);
        vm.expectRevert();
        router.liquidate(loanTerms);
    }

    function test__Liquidate_RevertWhen_BeforeGracePeriodEnd() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithGracePeriod(uint64(7 days));
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        (,, uint64 originationTs,) = router.loanState(loanTermsHash_);
        /* Warp to within grace period (after deadline but before grace ends) */
        vm.warp(_scheduleAt(loanTerms, originationTs)[0] + 1);
        vm.prank(users.liquidator);
        vm.expectRevert(ILoanRouterV2.InvalidLoanState.selector);
        router.liquidate(loanTerms);
    }

    function test__Liquidate_RevertWhen_NotActiveOrBreached() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);

        vm.prank(users.liquidator);
        router.setLoanBreach(loanTermsHash_);

        vm.prank(users.liquidator);
        router.liquidate(loanTerms);

        (ILoanRouterV2.LoanStatus statusBefore,,,) = router.loanState(loanTermsHash_);
        assertEq(uint8(statusBefore), uint8(ILoanRouterV2.LoanStatus.Liquidated));

        uint256 collateralTokenId = loanTerms.collateralTokenIds[0];
        address ownerBefore = collateralNft.ownerOf(collateralTokenId);

        vm.prank(users.liquidator);
        vm.expectRevert(ILoanRouterV2.InvalidLoanState.selector);
        router.liquidate(loanTerms);

        (ILoanRouterV2.LoanStatus statusAfter,,,) = router.loanState(loanTermsHash_);
        assertEq(uint8(statusAfter), uint8(ILoanRouterV2.LoanStatus.Liquidated));
        assertEq(collateralNft.ownerOf(collateralTokenId), ownerBefore);
    }

    function test__Liquidate_RevertWhen_Paused() public {
        /* liquidate() is not whenNotPaused per source. This test confirms that: pause should not affect liquidate. */
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        vm.prank(users.admin);
        router.pause();
        vm.prank(users.liquidator);
        router.setLoanBreach(loanTermsHash_);
        vm.prank(users.liquidator);
        router.liquidate(loanTerms);
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(loanTermsHash_);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Liquidated));
    }

    /*------------------------------------------------------------------------*/
    /* Test: events */
    /*------------------------------------------------------------------------*/

    function test__Liquidate_EmitsLoanLiquidated() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        vm.prank(users.liquidator);
        router.setLoanBreach(loanTermsHash_);
        vm.expectEmit(true, true, true, true, address(router));
        emit ILoanRouterV2.LoanLiquidated(loanTermsHash_);
        vm.prank(users.liquidator);
        router.liquidate(loanTerms);
    }

    /*------------------------------------------------------------------------*/
    /* Test: status matrix - extended reverts                                  */
    /*------------------------------------------------------------------------*/

    function test__Liquidate_RevertWhen_StatusUninitialized() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        uint256 collateralTokenId = loanTerms.collateralTokenIds[0];
        address ownerBefore = collateralNft.ownerOf(collateralTokenId);

        vm.prank(users.liquidator);
        vm.expectRevert(ILoanRouterV2.InvalidLoanState.selector);
        router.liquidate(loanTerms);

        (ILoanRouterV2.LoanStatus statusAfter,,,) = router.loanState(loanTermsHash_);
        assertEq(uint8(statusAfter), uint8(ILoanRouterV2.LoanStatus.Uninitialized));
        assertEq(collateralNft.ownerOf(collateralTokenId), ownerBefore);
    }

    function test__Liquidate_RevertWhen_StatusRepaid() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);

        /* Repay all cycles */
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

        (ILoanRouterV2.LoanStatus statusBefore,,,) = router.loanState(loanTermsHash_);
        assertEq(uint8(statusBefore), uint8(ILoanRouterV2.LoanStatus.Repaid));

        uint256 collateralTokenId = loanTerms.collateralTokenIds[0];
        address ownerBefore = collateralNft.ownerOf(collateralTokenId);

        vm.prank(users.liquidator);
        vm.expectRevert(ILoanRouterV2.InvalidLoanState.selector);
        router.liquidate(loanTerms);

        (ILoanRouterV2.LoanStatus statusAfter,,,) = router.loanState(loanTermsHash_);
        assertEq(uint8(statusAfter), uint8(ILoanRouterV2.LoanStatus.Repaid));
        assertEq(collateralNft.ownerOf(collateralTokenId), ownerBefore);
    }

    function test__Liquidate_RevertWhen_StatusCollateralLiquidated() public {
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

        (ILoanRouterV2.LoanStatus statusBefore,,,) = router.loanState(hash_);
        assertEq(uint8(statusBefore), uint8(ILoanRouterV2.LoanStatus.CollateralLiquidated));

        vm.prank(users.liquidator);
        vm.expectRevert(ILoanRouterV2.InvalidLoanState.selector);
        router.liquidate(loanTerms);

        (ILoanRouterV2.LoanStatus statusAfter,,,) = router.loanState(hash_);
        assertEq(uint8(statusAfter), uint8(ILoanRouterV2.LoanStatus.CollateralLiquidated));
    }

    /*------------------------------------------------------------------------*/
    /* Test: grace boundary                                                    */
    /*------------------------------------------------------------------------*/

    function test__Liquidate_AtExactGracePeriodEnd_Fails() public {
        uint64 graceDuration = uint64(7 days);
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithGracePeriod(graceDuration);
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        (,, uint64 originationTs,) = router.loanState(hash_);
        /* The check is `block.timestamp <= gracePeriodEnd`; equal-to is in-grace, so liquidation fails. */
        vm.warp(_scheduleAt(loanTerms, originationTs)[0] + graceDuration);
        vm.prank(users.liquidator);
        vm.expectRevert(ILoanRouterV2.InvalidLoanState.selector);
        router.liquidate(loanTerms);
    }

    function test__Liquidate_OneSecondPastGracePeriodEnd_Succeeds() public {
        uint64 graceDuration = uint64(7 days);
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithGracePeriod(graceDuration);
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        (,, uint64 originationTs,) = router.loanState(hash_);
        vm.warp(_scheduleAt(loanTerms, originationTs)[0] + graceDuration + 1);
        vm.prank(users.liquidator);
        router.liquidate(loanTerms);
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(hash_);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Liquidated));
    }

    /*------------------------------------------------------------------------*/
    /* Test: hook callbacks                                                    */
    /*------------------------------------------------------------------------*/

    function _originateWithLender(
        address lender
    ) internal returns (ILoanRouterV2.LoanTermsV2 memory loanTerms) {
        /* Top up the lender's USDai and approval */
        deal(USDAI, lender, 100_000_000 * 1e18);
        vm.prank(lender);
        IERC20Like(USDAI).approve(address(depositTimelock), type(uint256).max);

        vm.prank(users.deployer);
        AccessControl(address(depositTimelock)).grantRole(keccak256("DEPOSITOR_ROLE"), lender);

        /* Build single-tranche loanTerms with `lender` as the lender */
        RouterFixture.LoanConfig memory config = _defaultConfig();
        loanTerms = buildLoanTerms(config);
        loanTerms.trancheSpecs[0].lender = lender;

        vm.warp(_recipeTimestamp(config.variant));

        /* Lender deposits via DepositTimelock */
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        vm.prank(lender);
        depositTimelock.deposit(
            address(router), hash_, USDAI, loanTerms.trancheSpecs[0].amount, uint64(block.timestamp + 7 days)
        );

        /* Originate */
        prepareCollateralDeposit(loanTerms);
        ILoanRouterV2.LenderDepositInfo[] memory infos = new ILoanRouterV2.LenderDepositInfo[](1);
        infos[0] = ILoanRouterV2.LenderDepositInfo({depositType: ILoanRouterV2.DepositType.DepositTimelock, data: ""});
        originateLoan(loanTerms, infos, new bytes[](0));
    }

    function test__Liquidate_HookCalled_OnLenderContract() public {
        LenderHookRecorder hookLender = new LenderHookRecorder();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithLender(address(hookLender));
        bytes32 hash_ = router.loanTermsHash(loanTerms);

        vm.prank(users.liquidator);
        router.setLoanBreach(hash_);
        vm.prank(users.liquidator);
        router.liquidate(loanTerms);

        assertTrue(hookLender.onLoanLiquidatedCalled());
    }

    function test__Liquidate_HookRevert_EmitsHookFailed_Continues() public {
        LenderHookReverter hookLender = new LenderHookReverter();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithLender(address(hookLender));
        bytes32 hash_ = router.loanTermsHash(loanTerms);

        vm.prank(users.liquidator);
        router.setLoanBreach(hash_);
        /* Expect HookFailed event during liquidate; outer call still succeeds */
        vm.expectEmit(false, false, false, false, address(router));
        emit ILoanRouterV2.HookFailed("");
        vm.prank(users.liquidator);
        router.liquidate(loanTerms);

        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(hash_);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Liquidated));
    }

    function test__Liquidate_NoHookCalled_OnEOALender() public {
        /* Default lender for EscrowTimelock is STAKED_USDAI (a contract, but mocked to accept ERC721).
         * For a true EOA, use DepositTimelock with users.lender1 (also a contract per BaseTest? Actually it's
         * an EOA via makeAddr). Verify no hook is attempted: hook contract on lender1 would not exist, so
        * `_supportsHooksInterface(lender1)` returns false. We assert by observing that liquidate doesn't revert
         * AND no HookFailed event was emitted. */
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.useEscrowTimelock = false;
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateConfigured(config);
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        vm.prank(users.liquidator);
        router.setLoanBreach(hash_);
        /* recordLogs to confirm no HookFailed in the emitted log set */
        vm.recordLogs();
        vm.prank(users.liquidator);
        router.liquidate(loanTerms);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 hookFailedTopic = keccak256("HookFailed(string)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != hookFailedTopic);
        }
    }

    /*------------------------------------------------------------------------*/
    /* Test: multi-collateral NFTs                                             */
    /*------------------------------------------------------------------------*/

    function test__Liquidate_MultiCollateralNFTs_AllTransferredToLiquidator() public {
        /* Build a loan and extend it to 3 collateral NFTs */
        RouterFixture.LoanConfig memory config = _defaultConfig();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);

        /* Reuse the token already minted by buildLoanTerms and add two more */
        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = loanTerms.collateralTokenIds[0];
        for (uint256 i = 1; i < 3; i++) {
            uint256 newId = nextCollateralId++;
            collateralNft.mint(collateralDepositor, newId);
            tokenIds[i] = newId;
        }
        loanTerms.collateralTokenIds = tokenIds;

        vm.warp(_recipeTimestamp(config.variant));
        prepareLenderDeposits(loanTerms, true);
        prepareCollateralDeposit(loanTerms);
        originateLoan(loanTerms, buildDepositInfos(loanTerms, true), new bytes[](0));

        bytes32 hash_ = router.loanTermsHash(loanTerms);
        vm.prank(users.liquidator);
        router.setLoanBreach(hash_);
        vm.prank(users.liquidator);
        router.liquidate(loanTerms);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            assertEq(collateralNft.ownerOf(tokenIds[i]), users.liquidator);
        }
    }

    /*------------------------------------------------------------------------*/
    /* Test: liquidate after partial repayment                                 */
    /*------------------------------------------------------------------------*/

    function test__Liquidate_AfterPartialRepayment_Succeeds() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        (,, uint64 originationTs,) = router.loanState(hash_);

        /* Repay first 3 cycles */
        for (uint16 i = 0; i < 3; i++) {
            vm.warp(_scheduleAt(loanTerms, originationTs)[i]);
            (uint256 p, uint256 ii, uint256 f) = router.quote(loanTerms);
            uint256 total = p + ii + f;
            deal(USDAI, users.borrower, total + 1e20);
            vm.startPrank(users.borrower);
            IERC20Like(USDAI).approve(address(router), total);
            router.repay(loanTerms, total);
            vm.stopPrank();
        }

        /* Breach + liquidate */
        vm.prank(users.liquidator);
        router.setLoanBreach(hash_);
        vm.prank(users.liquidator);
        router.liquidate(loanTerms);

        (ILoanRouterV2.LoanStatus status,,, uint256 balance) = router.loanState(hash_);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Liquidated));
        assertGt(balance, 0); /* still some outstanding */
        assertEq(collateralNft.ownerOf(loanTerms.collateralTokenIds[0]), users.liquidator);
    }

    /*------------------------------------------------------------------------*/
    /* Test: lender NFT survives `liquidate` for later proceeds-deposit ownerOf reads */
    /*------------------------------------------------------------------------*/

    function test__Liquidate_LenderNFT_NotBurned() public {
        /* Originate a two-tranche loan */
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateTwoTranches();

        /* Capture lender position token IDs while the loan is still active */
        uint256[] memory tokenIds = router.loanTokenIds(loanTerms);

        /* Resolve the loan terms hash */
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);

        /* Breach and liquidate without depositing proceeds */
        vm.prank(users.liquidator);
        router.setLoanBreach(loanTermsHash_);
        vm.prank(users.liquidator);
        router.liquidate(loanTerms);

        /* Lender NFTs must still exist; depositLiquidationProceeds will read ownerOf next */
        assertEq(IERC721(address(router)).ownerOf(tokenIds[0]), users.lender1);
        assertEq(IERC721(address(router)).ownerOf(tokenIds[1]), users.lender2);
    }
}
