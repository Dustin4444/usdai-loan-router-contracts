// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RouterFixture} from "../helpers/RouterFixture.sol";

import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";

contract LoanRouterV2ViewsTest is RouterFixture {
    /*------------------------------------------------------------------------*/
    /* Test: immutable getters */
    /*------------------------------------------------------------------------*/

    function test__DepositTimelock_Getter_ReturnsImmutable() public view {
        assertEq(router.depositTimelock(), address(depositTimelock));
    }

    function test__EscrowTimelock_Getter_ReturnsImmutable() public view {
        assertEq(router.escrowTimelock(), address(escrowTimelock));
    }

    function test__FeeRecipient_Getter_ReflectsInitialValue() public view {
        assertEq(router.feeRecipient(), users.feeRecipient);
    }

    /*------------------------------------------------------------------------*/
    /* Test: loanTermsHash */
    /*------------------------------------------------------------------------*/

    function test__LoanTermsHash_DeterministicForStruct() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(_defaultConfig());
        bytes32 h1 = router.loanTermsHash(loanTerms);
        bytes32 h2 = router.loanTermsHash(loanTerms);
        assertEq(h1, h2);
    }

    function test__LoanTermsHash_DiffersOnBorrowerChange() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(_defaultConfig());
        bytes32 h1 = router.loanTermsHash(loanTerms);
        loanTerms.borrower = makeAddr("otherBorrower");
        bytes32 h2 = router.loanTermsHash(loanTerms);
        assertTrue(h1 != h2);
    }

    function test__LoanTermsHash_DiffersOnDurationChange() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(_defaultConfig());
        bytes32 h1 = router.loanTermsHash(loanTerms);
        loanTerms.repaymentSpec.totalDurationDays = 730;
        bytes32 h2 = router.loanTermsHash(loanTerms);
        assertTrue(h1 != h2);
    }

    function test__LoanTermsHash_DiffersOnTrancheAmountChange() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(_defaultConfig());
        bytes32 h1 = router.loanTermsHash(loanTerms);
        loanTerms.trancheSpecs[0].amount += 1;
        bytes32 h2 = router.loanTermsHash(loanTerms);
        assertTrue(h1 != h2);
    }

    /*------------------------------------------------------------------------*/
    /* Test: loanState before origination */
    /*------------------------------------------------------------------------*/

    function test__LoanState_BeforeOrigination_ReturnsUninitialized() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(_defaultConfig());
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);

        (ILoanRouterV2.LoanStatus status, uint16 repaymentCount, uint64 originationTimestamp, uint256 scaledBalance) =
            router.loanState(loanTermsHash_);

        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Uninitialized));
        assertEq(repaymentCount, 0);
        assertEq(scaledBalance, 0);
        assertEq(originationTimestamp, 0);
        /* `deadlines` is no longer stored; the on-demand helper would compute a schedule for any well-formed
           terms, so the uninitialized signal is now `originationTimestamp == 0`. */
    }

    /*------------------------------------------------------------------------*/
    /* Test: loanState after origination */
    /*------------------------------------------------------------------------*/

    function test__LoanState_ByHash_ReflectsActiveLoan() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);

        (ILoanRouterV2.LoanStatus status, uint16 repaymentCount, uint64 originationTimestamp, uint256 scaledBalance) =
            router.loanState(loanTermsHash_);

        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active));
        assertEq(repaymentCount, 0);
        assertEq(scaledBalance, LOAN_AMOUNT_USDAI); /* 18dp already */
        assertGt(originationTimestamp, 0);
        assertEq(_schedule(loanTerms).length, 37); /* Upper variant */
    }

    function test__LoanState_ByTokenId_MatchesByHash() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        uint256[] memory tokenIds = router.loanTokenIds(loanTerms);
        assertEq(tokenIds.length, 1);

        (ILoanRouterV2.LoanStatus statusByHash, uint16 countByHash, uint64 originByHash, uint256 balByHash) =
            router.loanState(loanTermsHash_);
        (
            ILoanRouterV2.LoanStatus statusByTokenId,
            uint16 countByTokenId,
            uint64 originByTokenId,
            uint256 balByTokenId
        ) = router.loanState(tokenIds[0]);

        assertEq(uint8(statusByHash), uint8(statusByTokenId));
        assertEq(countByHash, countByTokenId);
        assertEq(balByHash, balByTokenId);
        assertEq(originByHash, originByTokenId);
    }

    /*------------------------------------------------------------------------*/
    /* Test: loanTokenIds */
    /*------------------------------------------------------------------------*/

    function test__LoanTokenIds_ReturnsOneTokenIdPerTranche_SingleTranche() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        uint256[] memory tokenIds = router.loanTokenIds(loanTerms);
        assertEq(tokenIds.length, 1);
    }

    function test__LoanTokenIds_ReturnsOneTokenIdPerTranche_TwoTranches() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.twoTranches = true;
        config.useEscrowTimelock = false;
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateConfigured(config);
        uint256[] memory tokenIds = router.loanTokenIds(loanTerms);
        assertEq(tokenIds.length, 2);
        assertTrue(tokenIds[0] != tokenIds[1]);
    }

    /*------------------------------------------------------------------------*/
    /* Test: loanTermsHash - mutation matrix                                   */
    /*------------------------------------------------------------------------*/

    function _buildTermsForHashMutation() internal returns (ILoanRouterV2.LoanTermsV2 memory) {
        return buildLoanTerms(_defaultConfig());
    }

    function test__LoanTermsHash_DiffersOnExpirationChange() public {
        ILoanRouterV2.LoanTermsV2 memory terms = _buildTermsForHashMutation();
        bytes32 h1 = router.loanTermsHash(terms);
        terms.expiration += 1;
        bytes32 h2 = router.loanTermsHash(terms);
        assertTrue(h1 != h2);
    }

    function test__LoanTermsHash_DiffersOnCurrencyTokenChange() public {
        ILoanRouterV2.LoanTermsV2 memory terms = _buildTermsForHashMutation();
        bytes32 h1 = router.loanTermsHash(terms);
        terms.currencyToken = USDC;
        bytes32 h2 = router.loanTermsHash(terms);
        assertTrue(h1 != h2);
    }

    function test__LoanTermsHash_DiffersOnCollateralTokenChange() public {
        ILoanRouterV2.LoanTermsV2 memory terms = _buildTermsForHashMutation();
        bytes32 h1 = router.loanTermsHash(terms);
        terms.collateralToken = makeAddr("differentCollateralToken");
        bytes32 h2 = router.loanTermsHash(terms);
        assertTrue(h1 != h2);
    }

    function test__LoanTermsHash_DiffersOnCollateralTokenIdsChange() public {
        ILoanRouterV2.LoanTermsV2 memory terms = _buildTermsForHashMutation();
        bytes32 h1 = router.loanTermsHash(terms);
        terms.collateralTokenIds[0] += 1;
        bytes32 h2 = router.loanTermsHash(terms);
        assertTrue(h1 != h2);
    }

    function test__LoanTermsHash_DiffersOnInterestRateModelChange() public {
        ILoanRouterV2.LoanTermsV2 memory terms = _buildTermsForHashMutation();
        bytes32 h1 = router.loanTermsHash(terms);
        terms.interestRateSpec.model = makeAddr("differentIRM");
        bytes32 h2 = router.loanTermsHash(terms);
        assertTrue(h1 != h2);
    }

    function test__LoanTermsHash_DiffersOnInterestRateModelOptionsChange() public {
        ILoanRouterV2.LoanTermsV2 memory terms = _buildTermsForHashMutation();
        bytes32 h1 = router.loanTermsHash(terms);
        terms.interestRateSpec.options = abi.encode(uint64(1), uint256(2));
        bytes32 h2 = router.loanTermsHash(terms);
        assertTrue(h1 != h2);
    }

    function test__LoanTermsHash_DiffersOnTrancheRateChange() public {
        ILoanRouterV2.LoanTermsV2 memory terms = _buildTermsForHashMutation();
        bytes32 h1 = router.loanTermsHash(terms);
        terms.trancheSpecs[0].rate += 1;
        bytes32 h2 = router.loanTermsHash(terms);
        assertTrue(h1 != h2);
    }

    function test__LoanTermsHash_DiffersOnTrancheLenderChange() public {
        ILoanRouterV2.LoanTermsV2 memory terms = _buildTermsForHashMutation();
        bytes32 h1 = router.loanTermsHash(terms);
        terms.trancheSpecs[0].lender = makeAddr("differentLender");
        bytes32 h2 = router.loanTermsHash(terms);
        assertTrue(h1 != h2);
    }

    function test__LoanTermsHash_DiffersOnFeeSpecChange() public {
        ILoanRouterV2.LoanTermsV2 memory terms = _buildTermsForHashMutation();
        bytes32 h1 = router.loanTermsHash(terms);
        terms.feeSpecs = new ILoanRouterV2.FeeSpec[](1);
        terms.feeSpecs[0] = ILoanRouterV2.FeeSpec({
            model: address(ratioFeeModel),
            recipient: insuranceRecipient,
            kind: ILoanRouterV2.FeeKind.Repayment,
            options: ""
        });
        bytes32 h2 = router.loanTermsHash(terms);
        assertTrue(h1 != h2);
    }

    function test__LoanTermsHash_DiffersOnRepaymentDayChange() public {
        ILoanRouterV2.LoanTermsV2 memory terms = _buildTermsForHashMutation();
        bytes32 h1 = router.loanTermsHash(terms);
        terms.repaymentSpec.day = 15;
        bytes32 h2 = router.loanTermsHash(terms);
        assertTrue(h1 != h2);
    }

    function test__LoanTermsHash_DiffersOnTimezoneOffsetChange() public {
        ILoanRouterV2.LoanTermsV2 memory terms = _buildTermsForHashMutation();
        bytes32 h1 = router.loanTermsHash(terms);
        terms.repaymentSpec.timezoneOffsetSeconds = -18000;
        bytes32 h2 = router.loanTermsHash(terms);
        assertTrue(h1 != h2);
    }

    function test__LoanTermsHash_DiffersOnApprovalAddressesChange() public {
        ILoanRouterV2.LoanTermsV2 memory terms = _buildTermsForHashMutation();
        bytes32 h1 = router.loanTermsHash(terms);
        terms.approvalAddresses = new address[](1);
        terms.approvalAddresses[0] = makeAddr("approver");
        bytes32 h2 = router.loanTermsHash(terms);
        assertTrue(h1 != h2);
    }

    function test__LoanTermsHash_DiffersOnChainId() public {
        ILoanRouterV2.LoanTermsV2 memory terms = _buildTermsForHashMutation();
        uint256 originalChainId = block.chainid;
        bytes32 h1 = router.loanTermsHash(terms);
        vm.chainId(originalChainId + 1);
        bytes32 h2 = router.loanTermsHash(terms);
        vm.chainId(originalChainId);
        assertTrue(h1 != h2);
    }

    /*------------------------------------------------------------------------*/
    /* Test: loanState - content beyond shape                                  */
    /*------------------------------------------------------------------------*/

    function test__LoanState_DeadlinesContent_LastIsFirstAnchorAtOrAfterFloor() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        (,, uint64 originationTs,) = router.loanState(hash_);
        uint64[] memory schedule = _schedule(loanTerms);

        /* Duration floor */
        uint64 floor = originationTs + uint64(loanTerms.repaymentSpec.totalDurationDays) * 86400;

        /* The last deadline is the first repayment-day anchor at or after the floor */
        assertGe(schedule[schedule.length - 1], floor);
        assertLt(schedule[schedule.length - 2], floor);
    }

    function test__LoanState_RepaymentCountReflectsRepays() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        (,, uint64 originationTs,) = router.loanState(hash_);

        /* Warp to first deadline and repay */
        vm.warp(_scheduleAt(loanTerms, originationTs)[0]);
        (uint256 p, uint256 i, uint256 f) = router.quote(loanTerms);
        uint256 totalDue = p + i + f;
        deal(USDAI, users.borrower, totalDue + 1e20);
        vm.startPrank(users.borrower);
        IERC20(USDAI).approve(address(router), totalDue);
        router.repay(loanTerms, totalDue);
        vm.stopPrank();

        (, uint16 count,,) = router.loanState(hash_);
        assertEq(count, 1);
    }

    function test__LoanState_BalanceDecreasesWithRepay() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        (,, uint64 originationTs, uint256 balBefore) = router.loanState(hash_);
        uint64[] memory schedule = _scheduleAt(loanTerms, originationTs);

        /* Cycle 0 is an interest-only stub, so the balance is unchanged after it */
        _repayAt(loanTerms, schedule[0]);
        (,,, uint256 balAfterStub) = router.loanState(hash_);
        assertEq(balAfterStub, balBefore, "Stub repayment leaves principal untouched");

        /* Cycle 1 pays principal, so the balance strictly decreases */
        _repayAt(loanTerms, schedule[1]);
        (,,, uint256 balAfter) = router.loanState(hash_);
        assertLt(balAfter, balBefore, "Principal repayment decreases the balance");
    }

    /*------------------------------------------------------------------------*/
    /* Test: loanState by tokenId - non-existent                               */
    /*------------------------------------------------------------------------*/

    function test__LoanState_ByTokenId_NonExistent_ReturnsUninitialized() public view {
        (ILoanRouterV2.LoanStatus status, uint16 count, uint64 origination, uint256 balance) =
            router.loanState(uint256(0xDEAD));
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Uninitialized));
        assertEq(count, 0);
        assertEq(balance, 0);
        assertEq(origination, 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: loanTokenIds - determinism and uniqueness                         */
    /*------------------------------------------------------------------------*/

    function test__LoanTokenIds_DeterministicAcrossCalls() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        uint256[] memory tokenIds1 = router.loanTokenIds(loanTerms);
        uint256[] memory tokenIds2 = router.loanTokenIds(loanTerms);
        assertEq(tokenIds1.length, tokenIds2.length);
        assertEq(tokenIds1[0], tokenIds2[0]);
    }

    function test__LoanTokenIds_AllUniqueForMaxTranches() public {
        /* Build a synthetic 32-tranche LoanTermsV2 (no origination — function is view) */
        ILoanRouterV2.LoanTermsV2 memory terms = buildLoanTerms(_defaultConfig());
        ILoanRouterV2.TrancheSpec[] memory specs = new ILoanRouterV2.TrancheSpec[](32);
        for (uint8 i = 0; i < 32; i++) {
            specs[i] = ILoanRouterV2.TrancheSpec({
                lender: address(uint160(0x1000 + i)), amount: 1_000_000 * 1e18, rate: RATE_8_5_PCT
            });
        }
        terms.trancheSpecs = specs;

        uint256[] memory tokenIds = router.loanTokenIds(terms);
        assertEq(tokenIds.length, 32);
        /* All unique: pairwise check */
        for (uint256 i = 0; i < 32; i++) {
            for (uint256 j = i + 1; j < 32; j++) {
                assertTrue(tokenIds[i] != tokenIds[j]);
            }
        }
    }
}
