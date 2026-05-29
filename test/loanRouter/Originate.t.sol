// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Vm} from "forge-std/Vm.sol";

import {RouterFixture} from "../helpers/RouterFixture.sol";
import {LoanFixtures} from "../helpers/LoanFixtures.sol";
import {LenderHookRecorder} from "../mocks/LenderHookRecorder.sol";
import {ERC1271SignerMock} from "../mocks/ERC1271SignerMock.sol";

import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {ILoanRouterV2Hooks} from "src/interfaces/ILoanRouterV2Hooks.sol";
import {RatioFeeModel} from "src/fees/RatioFeeModel.sol";
import {AbsoluteFeeModel} from "src/fees/AbsoluteFeeModel.sol";

contract LoanRouterV2OriginateTest is RouterFixture {
    /*------------------------------------------------------------------------*/
    /* Test: happy paths - window variants */
    /*------------------------------------------------------------------------*/

    function test__Originate_HappyPath_1095Days_37Deadlines() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        assertEq(_schedule(loanTerms).length, 37);
    }

    function test__Originate_HappyPath_1095Days_36Deadlines() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.variant = LoanFixtures.WindowVariant.Lower;
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateConfigured(config);
        assertEq(_schedule(loanTerms).length, 36);
    }

    /*------------------------------------------------------------------------*/
    /* Test: duration sweep */
    /*------------------------------------------------------------------------*/

    function _originateForDuration(
        uint16 durationDays
    ) internal returns (ILoanRouterV2.LoanTermsV2 memory) {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.durationDays = durationDays;
        return originateConfigured(config);
    }

    function test__Originate_DurationSweep_1Day() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateForDuration(1);
        assertEq(_schedule(loanTerms).length, 1); /* maturity only: no monthly anchor fits */
    }

    function test__Originate_DurationSweep_28Days() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateForDuration(28);
        uint256 count = _schedule(loanTerms).length;
        assertGe(count, 1);
        assertLe(count, 2);
    }

    function test__Originate_DurationSweep_30Days() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateForDuration(30);
        uint256 count = _schedule(loanTerms).length;
        assertGe(count, 1);
        assertLe(count, 2);
    }

    function test__Originate_DurationSweep_90Days() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateForDuration(90);
        uint256 count = _schedule(loanTerms).length;
        assertGe(count, 3);
        assertLe(count, 4);
    }

    function test__Originate_DurationSweep_365Days() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateForDuration(365);
        uint256 count = _schedule(loanTerms).length;
        assertGe(count, 12);
        assertLe(count, 13);
    }

    function test__Originate_DurationSweep_730Days() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateForDuration(730);
        uint256 count = _schedule(loanTerms).length;
        assertGe(count, 24);
        assertLe(count, 25);
    }

    function test__Originate_DurationSweep_1825Days() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateForDuration(1825);
        uint256 count = _schedule(loanTerms).length;
        assertGe(count, 60);
        assertLe(count, 61);
    }

    /*------------------------------------------------------------------------*/
    /* Test: repayment day clamping */
    /*------------------------------------------------------------------------*/

    function test__Originate_RepaymentDay_31_OriginatesWithoutRevert() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.repaymentDay = 31;
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateConfigured(config);
        /* Schedule should still produce 36-37 deadlines for the 1095-day case */
        uint256 count = _schedule(loanTerms).length;
        assertGe(count, 36);
        assertLe(count, 37);
    }

    function test__Originate_RepaymentDay_30_OriginatesActiveLoan() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.repaymentDay = 30;
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateConfigured(config);

        /* Schedule should still produce 36-37 deadlines for the 1095-day case */
        uint256 count = _schedule(loanTerms).length;
        assertGe(count, 36);
        assertLe(count, 37);

        /* Loan must be in Active state with non-zero scaled balance */
        (ILoanRouterV2.LoanStatus status,,, uint256 scaledBalance) = router.loanState(router.loanTermsHash(loanTerms));
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active));
        assertGt(scaledBalance, 0);
    }

    function test__Originate_RepaymentDay_29_OriginatesActiveLoan() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.repaymentDay = 29;
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateConfigured(config);

        uint256 count = _schedule(loanTerms).length;
        assertGe(count, 36);
        assertLe(count, 37);

        (ILoanRouterV2.LoanStatus status,,, uint256 scaledBalance) = router.loanState(router.loanTermsHash(loanTerms));
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active));
        assertGt(scaledBalance, 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: multi-tranche */
    /*------------------------------------------------------------------------*/

    function test__Originate_TwoTranches_DepositTimelock() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.twoTranches = true;
        config.useEscrowTimelock = false;
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateConfigured(config);
        (,,, uint256 scaledBalance) = router.loanState(router.loanTermsHash(loanTerms));
        assertEq(scaledBalance, 50_000_000 * 1e18);
        /* Verify both tranche owners hold their lender NFTs */
        uint256[] memory tokenIds = router.loanTokenIds(loanTerms);
        assertEq(tokenIds.length, 2);
    }

    /*------------------------------------------------------------------------*/
    /* Test: deposit type variants */
    /*------------------------------------------------------------------------*/

    function test__Originate_SingleTranche_DepositTimelock() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.useEscrowTimelock = false;
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateConfigured(config);
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(router.loanTermsHash(loanTerms));
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active));
    }

    function test__Originate_Mixed_EscrowAndDepositTimelock() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.twoTranches = true;
        config.mixedDepositTypes = true; /* tranche 0 EscrowTimelock, tranche 1 DepositTimelock */
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateConfigured(config);
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(router.loanTermsHash(loanTerms));
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active));
    }

    /*------------------------------------------------------------------------*/
    /* Test: insurance fee variants */
    /*------------------------------------------------------------------------*/

    function test__Originate_PercentageInsuranceFeeWired() public {
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
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateConfigured(config);
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(router.loanTermsHash(loanTerms));
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active));
    }

    /*------------------------------------------------------------------------*/
    /* Test: approval signatures */
    /*------------------------------------------------------------------------*/

    function test__Originate_Success_WithSingleApproval() public {
        (address approver, uint256 approverPk) = makeAddrAndKey("approver");
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.approvalAddresses = new address[](1);
        config.approvalAddresses[0] = approver;

        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        vm.warp(_recipeTimestamp(config.variant));
        prepareLenderDeposits(loanTerms, true);
        prepareCollateralDeposit(loanTerms);

        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = signLoanTermsApproval(approverPk, loanTermsHash_);

        originateLoan(loanTerms, buildDepositInfos(loanTerms, true), signatures);
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(loanTermsHash_);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active));
    }

    function test__Originate_RevertWhen_WrongSigner() public {
        (address approver,) = makeAddrAndKey("approver");
        (, uint256 attackerPk) = makeAddrAndKey("attacker");
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.approvalAddresses = new address[](1);
        config.approvalAddresses[0] = approver;

        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        vm.warp(_recipeTimestamp(config.variant));
        prepareLenderDeposits(loanTerms, true);

        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = signLoanTermsApproval(attackerPk, loanTermsHash_); /* wrong signer */

        vm.prank(users.deployer);
        vm.expectRevert(ILoanRouterV2.InvalidSignature.selector);
        router.originate(loanTerms, buildDepositInfos(loanTerms, true), signatures);
    }

    function test__Originate_Approval_ERC1271_Succeeds() public {
        /* Deploy a contract signer that will pre-approve the upcoming digest */
        ERC1271SignerMock signer = new ERC1271SignerMock();

        /* Set the signer as the sole approval address */
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.approvalAddresses = new address[](1);
        config.approvalAddresses[0] = address(signer);

        /* Build the loan and prepare lender deposits */
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        vm.warp(_recipeTimestamp(config.variant));
        prepareLenderDeposits(loanTerms, true);
        prepareCollateralDeposit(loanTerms);

        /* Pre-approve the EIP-712 digest the router will check */
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        signer.setExpectedHash(_approvalDigest(loanTermsHash_));

        /* Signature bytes are opaque to the mock */
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = bytes("ERC1271-opaque");

        /* Originate should succeed */
        originateLoan(loanTerms, buildDepositInfos(loanTerms, true), signatures);
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(loanTermsHash_);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active));
    }

    function test__Originate_Approval_ERC1271_RevertWhen_WrongDigest() public {
        /* Contract signer pre-approves a different hash than the router will check */
        ERC1271SignerMock signer = new ERC1271SignerMock();
        signer.setExpectedHash(keccak256("not-the-real-digest"));

        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.approvalAddresses = new address[](1);
        config.approvalAddresses[0] = address(signer);

        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        vm.warp(_recipeTimestamp(config.variant));
        prepareLenderDeposits(loanTerms, true);

        /* Opaque blob; the mock will reject because expectedHash mismatches */
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = bytes("ERC1271-opaque");

        vm.prank(users.deployer);
        vm.expectRevert(ILoanRouterV2.InvalidSignature.selector);
        router.originate(loanTerms, buildDepositInfos(loanTerms, true), signatures);
    }

    function test__Originate_Approval_ERC1271_RevertWhen_NotASigner() public {
        /* A contract that has code but doesn't implement isValidSignature */
        address notASigner = address(new LenderHookRecorder());

        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.approvalAddresses = new address[](1);
        config.approvalAddresses[0] = notASigner;

        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        vm.warp(_recipeTimestamp(config.variant));
        prepareLenderDeposits(loanTerms, true);

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = bytes("anything");

        vm.prank(users.deployer);
        vm.expectRevert(ILoanRouterV2.InvalidSignature.selector);
        router.originate(loanTerms, buildDepositInfos(loanTerms, true), signatures);
    }

    /*------------------------------------------------------------------------*/
    /* Test: revert matrix - validateLoanTerms */
    /*------------------------------------------------------------------------*/

    function test__Originate_RevertWhen_ExpiredTerms() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        vm.warp(_recipeTimestamp(config.variant));
        prepareLenderDeposits(loanTerms, true);
        loanTerms.expiration = uint64(block.timestamp - 1); /* expired */

        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Expiration"));
        router.originate(loanTerms, buildDepositInfos(loanTerms, true), new bytes[](0));
    }

    function test__Originate_RevertWhen_InvalidRepaymentDay_Zero() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.repaymentDay = 1; /* placeholder */
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        vm.warp(_recipeTimestamp(config.variant));
        prepareLenderDeposits(loanTerms, true);
        loanTerms.repaymentSpec.day = 0;

        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Repayment Day"));
        router.originate(loanTerms, buildDepositInfos(loanTerms, true), new bytes[](0));
    }

    function test__Originate_RevertWhen_InvalidRepaymentDay_GreaterThan31() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        vm.warp(_recipeTimestamp(config.variant));
        prepareLenderDeposits(loanTerms, true);
        loanTerms.repaymentSpec.day = 32;

        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Repayment Day"));
        router.originate(loanTerms, buildDepositInfos(loanTerms, true), new bytes[](0));
    }

    function test__Originate_RevertWhen_ZeroDuration() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        vm.warp(_recipeTimestamp(config.variant));
        prepareLenderDeposits(loanTerms, true);
        loanTerms.repaymentSpec.totalDurationDays = 0;

        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Loan Duration Days"));
        router.originate(loanTerms, buildDepositInfos(loanTerms, true), new bytes[](0));
    }

    /*------------------------------------------------------------------------*/
    /* Test: revert matrix - access control and state */
    /*------------------------------------------------------------------------*/

    function test__Originate_RevertWhen_NotOriginator() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        vm.warp(_recipeTimestamp(config.variant));
        prepareLenderDeposits(loanTerms, true);

        vm.prank(users.borrower); /* not ORIGINATOR_ROLE */
        vm.expectRevert();
        router.originate(loanTerms, buildDepositInfos(loanTerms, true), new bytes[](0));
    }

    function test__Originate_RevertWhen_LoanAlreadyActive() public {
        /* Originate once, then try again with the same terms */
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();

        vm.prank(users.deployer);
        vm.expectRevert(ILoanRouterV2.InvalidLoanState.selector);
        router.originate(loanTerms, buildDepositInfos(loanTerms, true), new bytes[](0));
    }

    function test__Originate_RevertWhen_DepositInfosLengthMismatch() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        vm.warp(_recipeTimestamp(config.variant));
        prepareLenderDeposits(loanTerms, true);

        ILoanRouterV2.LenderDepositInfo[] memory infos = new ILoanRouterV2.LenderDepositInfo[](2); /* wrong length */
        vm.prank(users.deployer);
        vm.expectRevert(ILoanRouterV2.InvalidLength.selector);
        router.originate(loanTerms, infos, new bytes[](0));
    }

    /*------------------------------------------------------------------------*/
    /* Test: side effects */
    /*------------------------------------------------------------------------*/

    function test__Originate_TokenizesLendingPositions_MintsToLender() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        uint256[] memory tokenIds = router.loanTokenIds(loanTerms);
        assertEq(tokenIds.length, 1);
        /* Direct ownership check via the router's ERC721 surface — single-tranche EscrowTimelock → lender =
        STAKED_USDAI */
        (bool ok, bytes memory data) =
            address(router).staticcall(abi.encodeWithSignature("ownerOf(uint256)", tokenIds[0]));
        assertTrue(ok);
        address owner = abi.decode(data, (address));
        assertEq(owner, STAKED_USDAI);
    }

    function test__Originate_TransfersCollateralFromEscrow() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        assertEq(collateralNft.ownerOf(loanTerms.collateralTokenIds[0]), address(router));
    }

    /*------------------------------------------------------------------------*/
    /* Test: validateLoanTerms matrix — remaining branches                     */
    /*------------------------------------------------------------------------*/

    function _buildAndPrepareDeposits() internal returns (ILoanRouterV2.LoanTermsV2 memory loanTerms) {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        loanTerms = buildLoanTerms(config);
        vm.warp(_recipeTimestamp(config.variant));
        prepareLenderDeposits(loanTerms, true);
    }

    function _expectInvalidLoanTerms(
        ILoanRouterV2.LoanTermsV2 memory loanTerms,
        string memory reason
    ) internal {
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, reason));
        router.originate(loanTerms, buildDepositInfos(loanTerms, true), new bytes[](0));
    }

    function test__Originate_RevertWhen_BorrowerZero() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _buildAndPrepareDeposits();
        loanTerms.borrower = address(0);
        _expectInvalidLoanTerms(loanTerms, "Borrower");
    }

    function test__Originate_RevertWhen_CurrencyTokenZero() public {
        /* The `scaleFactor` modifier runs FIRST and calls `IERC20Metadata(currencyToken).decimals()`. With
        * currencyToken=0, that low-level call to a zero address reverts with no data — *before* validateLoanTerms
        * gets a chance to fire the "Currency Token" branch. We just confirm the call reverts; the exact selector
         * isn't reachable for this input. */
        RouterFixture.LoanConfig memory config = _defaultConfig();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        vm.warp(_recipeTimestamp(config.variant));
        loanTerms.currencyToken = address(0);
        ILoanRouterV2.LenderDepositInfo[] memory infos = buildDepositInfos(loanTerms, true);
        vm.prank(users.deployer);
        vm.expectRevert();
        router.originate(loanTerms, infos, new bytes[](0));
    }

    function test__Originate_RevertWhen_CollateralTokenZero() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _buildAndPrepareDeposits();
        loanTerms.collateralToken = address(0);
        _expectInvalidLoanTerms(loanTerms, "Collateral Token");
    }

    function test__Originate_RevertWhen_NoCollateralIds() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _buildAndPrepareDeposits();
        loanTerms.collateralTokenIds = new uint256[](0);
        _expectInvalidLoanTerms(loanTerms, "Collateral Token IDs");
    }

    function test__Originate_RevertWhen_InterestRateModelZero() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _buildAndPrepareDeposits();
        loanTerms.interestRateSpec.model = address(0);
        _expectInvalidLoanTerms(loanTerms, "Interest Rate Model");
    }

    function test__Originate_RevertWhen_NoTranches() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _buildAndPrepareDeposits();
        loanTerms.trancheSpecs = new ILoanRouterV2.TrancheSpec[](0);
        vm.prank(users.deployer);
        vm.expectRevert();
        router.originate(loanTerms, new ILoanRouterV2.LenderDepositInfo[](0), new bytes[](0));
    }

    function test__Originate_RevertWhen_TooManyTranches() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _buildAndPrepareDeposits();
        ILoanRouterV2.TrancheSpec[] memory tranches = new ILoanRouterV2.TrancheSpec[](33);
        for (uint256 i = 0; i < 33; i++) {
            tranches[i] = ILoanRouterV2.TrancheSpec({
                lender: address(uint160(0x2000 + i)), amount: 1_000_000 * 1e18, rate: RATE_8_5_PCT
            });
        }
        loanTerms.trancheSpecs = tranches;
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Tranche Specs"));
        router.originate(loanTerms, new ILoanRouterV2.LenderDepositInfo[](33), new bytes[](0));
    }

    function test__Originate_RevertWhen_InvalidTimezoneTooNegative() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _buildAndPrepareDeposits();
        loanTerms.repaymentSpec.timezoneOffsetSeconds = -43201; /* one second below -43200 */
        _expectInvalidLoanTerms(loanTerms, "Timezone Offset");
    }

    function test__Originate_RevertWhen_InvalidTimezoneTooPositive() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _buildAndPrepareDeposits();
        loanTerms.repaymentSpec.timezoneOffsetSeconds = 50401; /* one second above 50400 */
        _expectInvalidLoanTerms(loanTerms, "Timezone Offset");
    }

    function test__Originate_RevertWhen_FeeSpecValidateDecodingReverts() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _buildAndPrepareDeposits();
        loanTerms.feeSpecs = new ILoanRouterV2.FeeSpec[](1);
        loanTerms.feeSpecs[0] = ILoanRouterV2.FeeSpec({
            model: address(ratioFeeModel),
            recipient: insuranceRecipient,
            kind: ILoanRouterV2.FeeKind.Origination,
            options: hex"deadbeef" /* malformed — too short to decode Options */
        });
        vm.prank(users.deployer);
        vm.expectRevert();
        router.originate(loanTerms, buildDepositInfos(loanTerms, true), new bytes[](0));
    }

    /*------------------------------------------------------------------------*/
    /* Test: approval signatures — extended                                    */
    /*------------------------------------------------------------------------*/

    function test__Originate_Success_WithMultipleApprovals() public {
        (address approver1, uint256 pk1) = makeAddrAndKey("approver1");
        (address approver2, uint256 pk2) = makeAddrAndKey("approver2");
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.approvalAddresses = new address[](2);
        config.approvalAddresses[0] = approver1;
        config.approvalAddresses[1] = approver2;

        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        vm.warp(_recipeTimestamp(config.variant));
        prepareLenderDeposits(loanTerms, true);
        prepareCollateralDeposit(loanTerms);
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = signLoanTermsApproval(pk1, hash_);
        sigs[1] = signLoanTermsApproval(pk2, hash_);
        originateLoan(loanTerms, buildDepositInfos(loanTerms, true), sigs);

        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(hash_);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active));
    }

    function test__Originate_RevertWhen_SignatureLengthMismatch() public {
        (address approver,) = makeAddrAndKey("approver");
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.approvalAddresses = new address[](1);
        config.approvalAddresses[0] = approver;
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        vm.warp(_recipeTimestamp(config.variant));
        prepareLenderDeposits(loanTerms, true);

        bytes[] memory sigs = new bytes[](0); /* mismatch */
        vm.prank(users.deployer);
        vm.expectRevert(); /* validateApprovals reverts */
        router.originate(loanTerms, buildDepositInfos(loanTerms, true), sigs);
    }

    /*------------------------------------------------------------------------*/
    /* Test: origination fee paths                                             */
    /*------------------------------------------------------------------------*/

    function test__Originate_PaysOriginationFee_Percentage_DepositTimelock() public {
        /* 1% origination fee on principal; use DepositTimelock so fees are paid on-chain */
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.useEscrowTimelock = false;
        config.feeSpecs = new ILoanRouterV2.FeeSpec[](1);
        config.feeSpecs[0] = ILoanRouterV2.FeeSpec({
            model: address(ratioFeeModel),
            recipient: insuranceRecipient,
            kind: ILoanRouterV2.FeeKind.Origination,
            options: abi.encode(RatioFeeModel.Options({mode: RatioFeeModel.Mode.Amount, rate: 0.01e18}))
        });

        uint256 recipientBefore = IERC20(USDAI).balanceOf(insuranceRecipient);
        uint256 borrowerBefore = IERC20(USDAI).balanceOf(users.borrower);
        originateConfigured(config);
        /* Fee recipient gained exactly 1% of $50M = $500k */
        assertEq(IERC20(USDAI).balanceOf(insuranceRecipient) - recipientBefore, 500_000 * 1e18);
        /* Borrower received principal - fee = $50M - $500k = $49.5M */
        assertEq(IERC20(USDAI).balanceOf(users.borrower) - borrowerBefore, 49_500_000 * 1e18);
    }

    function test__Originate_PaysOriginationFee_Absolute_DepositTimelock() public {
        /* Fixed $500k origination fee; use DepositTimelock so fees are paid on-chain */
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.useEscrowTimelock = false;
        config.feeSpecs = new ILoanRouterV2.FeeSpec[](1);
        config.feeSpecs[0] = ILoanRouterV2.FeeSpec({
            model: address(absoluteFeeModel),
            recipient: insuranceRecipient,
            kind: ILoanRouterV2.FeeKind.Origination,
            options: abi.encode(AbsoluteFeeModel.Options({amount: 500_000 * 1e18}))
        });

        uint256 recipientBefore = IERC20(USDAI).balanceOf(insuranceRecipient);
        uint256 borrowerBefore = IERC20(USDAI).balanceOf(users.borrower);
        originateConfigured(config);
        /* Fee recipient gained exactly $500k */
        assertEq(IERC20(USDAI).balanceOf(insuranceRecipient) - recipientBefore, 500_000 * 1e18);
        /* Borrower received principal - fee = $50M - $500k = $49.5M */
        assertEq(IERC20(USDAI).balanceOf(users.borrower) - borrowerBefore, 49_500_000 * 1e18);
    }

    function test__Originate_EscrowTimelock_OriginationFeeNotPaidOnChain() public {
        /* With EscrowTimelock funding, hasOffchainFunds = true → origination fee is computed but NOT transferred. */
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.feeSpecs = new ILoanRouterV2.FeeSpec[](1);
        config.feeSpecs[0] = ILoanRouterV2.FeeSpec({
            model: address(ratioFeeModel),
            recipient: insuranceRecipient,
            kind: ILoanRouterV2.FeeKind.Origination,
            options: abi.encode(RatioFeeModel.Options({mode: RatioFeeModel.Mode.Amount, rate: 0.01e18}))
        });

        uint256 recipientBefore = IERC20(USDAI).balanceOf(insuranceRecipient);
        originateConfigured(config);
        /* No on-chain transfer — offchain settlement is implied */
        assertEq(IERC20(USDAI).balanceOf(insuranceRecipient), recipientBefore);
    }

    /*------------------------------------------------------------------------*/
    /* Test: events                                                            */
    /*------------------------------------------------------------------------*/

    function test__Originate_EmitsLoanOriginated_WithCorrectArgs() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        vm.warp(_recipeTimestamp(config.variant));
        prepareLenderDeposits(loanTerms, true);
        prepareCollateralDeposit(loanTerms);
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        vm.expectEmit(true, true, true, true, address(router));
        emit ILoanRouterV2.LoanOriginated(hash_, users.borrower, USDAI, LOAN_AMOUNT_USDAI, 0);
        vm.prank(users.deployer);
        router.originate(loanTerms, buildDepositInfos(loanTerms, true), new bytes[](0));
    }

    function test__Originate_EmitsLenderPositionMinted_PerTranche() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.twoTranches = true;
        config.useEscrowTimelock = false;
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        vm.warp(_recipeTimestamp(config.variant));
        prepareLenderDeposits(loanTerms, false);
        prepareCollateralDeposit(loanTerms);
        bytes32 hash_ = router.loanTermsHash(loanTerms);

        vm.recordLogs();
        originateLoan(loanTerms, buildDepositInfos(loanTerms, false), new bytes[](0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("LenderPositionMinted(bytes32,address,uint8,uint256)");
        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic && logs[i].topics[1] == hash_) count++;
        }
        assertEq(count, 2);
    }

    /*------------------------------------------------------------------------*/
    /* Test: hooks                                                             */
    /*------------------------------------------------------------------------*/

    function test__Originate_HookCalled_OnLenderContract() public {
        LenderHookRecorder hookLender = new LenderHookRecorder();
        deal(USDAI, address(hookLender), 100_000_000 * 1e18);
        vm.prank(address(hookLender));
        IERC20(USDAI).approve(address(depositTimelock), type(uint256).max);

        vm.prank(users.deployer);
        AccessControl(address(depositTimelock)).grantRole(keccak256("DEPOSITOR_ROLE"), address(hookLender));

        RouterFixture.LoanConfig memory config = _defaultConfig();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        loanTerms.trancheSpecs[0].lender = address(hookLender);
        vm.warp(_recipeTimestamp(config.variant));
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        vm.prank(address(hookLender));
        depositTimelock.deposit(
            address(router), hash_, USDAI, loanTerms.trancheSpecs[0].amount, uint64(block.timestamp + 7 days)
        );
        prepareCollateralDeposit(loanTerms);
        ILoanRouterV2.LenderDepositInfo[] memory infos = new ILoanRouterV2.LenderDepositInfo[](1);
        infos[0] = ILoanRouterV2.LenderDepositInfo({depositType: ILoanRouterV2.DepositType.DepositTimelock, data: ""});
        originateLoan(loanTerms, infos, new bytes[](0));

        assertTrue(hookLender.onLoanOriginatedCalled());
    }

    function test__Originate_HookRevert_PropagatesAndRevertsOrigination() public {
        /* Use a custom mock that reverts on onLoanOriginated. We define it inline via a tiny abuse of
        LenderHookReverter:
        * the original reverter doesn't revert on origin (per the lifecycle convention), so we use a dedicated mock. */
        OriginRevertingLender hookLender = new OriginRevertingLender();
        deal(USDAI, address(hookLender), 100_000_000 * 1e18);
        vm.prank(address(hookLender));
        IERC20(USDAI).approve(address(depositTimelock), type(uint256).max);

        vm.prank(users.deployer);
        AccessControl(address(depositTimelock)).grantRole(keccak256("DEPOSITOR_ROLE"), address(hookLender));

        RouterFixture.LoanConfig memory config = _defaultConfig();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        loanTerms.trancheSpecs[0].lender = address(hookLender);
        vm.warp(_recipeTimestamp(config.variant));
        bytes32 hash_ = router.loanTermsHash(loanTerms);
        vm.prank(address(hookLender));
        depositTimelock.deposit(
            address(router), hash_, USDAI, loanTerms.trancheSpecs[0].amount, uint64(block.timestamp + 7 days)
        );
        prepareCollateralDeposit(loanTerms);
        ILoanRouterV2.LenderDepositInfo[] memory infos = new ILoanRouterV2.LenderDepositInfo[](1);
        infos[0] = ILoanRouterV2.LenderDepositInfo({depositType: ILoanRouterV2.DepositType.DepositTimelock, data: ""});

        vm.prank(users.deployer);
        vm.expectRevert(OriginRevertingLender.OriginHookReverted.selector);
        router.originate(loanTerms, infos, new bytes[](0));
    }

    /*------------------------------------------------------------------------*/
    /* Test: other                                                             */
    /*------------------------------------------------------------------------*/

    function test__Originate_Pause_DoesNotBlock() public {
        vm.prank(users.admin);
        router.pause();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(router.loanTermsHash(loanTerms));
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active));
    }

    function test__Originate_MultiCollateralNFTs_AllTransferred() public {
        RouterFixture.LoanConfig memory config = _defaultConfig();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);

        /* Reuse the token already minted by buildLoanTerms and add two more */
        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = loanTerms.collateralTokenIds[0];
        for (uint256 i = 1; i < 3; i++) {
            uint256 id = nextCollateralId++;
            collateralNft.mint(collateralDepositor, id);
            tokenIds[i] = id;
        }
        loanTerms.collateralTokenIds = tokenIds;

        vm.warp(_recipeTimestamp(config.variant));
        prepareLenderDeposits(loanTerms, true);
        prepareCollateralDeposit(loanTerms);
        originateLoan(loanTerms, buildDepositInfos(loanTerms, true), new bytes[](0));

        for (uint256 i = 0; i < tokenIds.length; i++) {
            assertEq(collateralNft.ownerOf(tokenIds[i]), address(router));
        }
    }
}

contract OriginRevertingLender is IERC165, IERC721Receiver, ILoanRouterV2Hooks {
    error OriginHookReverted();

    function onLoanOriginated(
        ILoanRouterV2.LoanTermsV2 calldata,
        bytes32,
        uint8
    ) external pure {
        revert OriginHookReverted();
    }

    function onLoanRepayment(
        ILoanRouterV2.LoanTermsV2 calldata,
        bytes32,
        uint8,
        uint256,
        uint256,
        uint256,
        uint256
    ) external pure {}

    function onLoanFeePaid(
        ILoanRouterV2.LoanTermsV2 calldata,
        bytes32,
        uint8,
        uint256
    ) external pure {}

    function onLoanLiquidated(
        ILoanRouterV2.LoanTermsV2 calldata,
        bytes32,
        uint8
    ) external pure {}

    function onLoanCollateralLiquidated(
        ILoanRouterV2.LoanTermsV2 calldata,
        bytes32,
        uint8,
        uint256,
        uint256
    ) external pure {}

    function supportsInterface(
        bytes4 interfaceId
    ) external pure returns (bool) {
        return interfaceId == type(ILoanRouterV2Hooks).interfaceId || interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IERC721Receiver).interfaceId;
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
