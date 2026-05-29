// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RouterFixture} from "../helpers/RouterFixture.sol";
import {BundleCollateralWrapper} from "../helpers/BundleCollateralWrapper.sol";
import {LenderHookRecorder} from "../mocks/LenderHookRecorder.sol";
import {LoanRouterV2} from "src/LoanRouterV2.sol";

import {ILoanRouterV1} from "src/interfaces/ILoanRouterV1.sol";
import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {SimpleInterestRateModel} from "src/rates/SimpleInterestRateModel.sol";
import {AbsoluteFeeModel} from "src/fees/AbsoluteFeeModel.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title LoanRouterV1Stub
 * @notice Minimal stand-in for the deployed V1 LoanRouter. Replace with the real V1 contract
 *         once the V1 upgrade (adding migrateOut) is deployed.
 */
contract LoanRouterV1Stub is ILoanRouterV1 {
    struct StoredState {
        LoanStatus status;
        uint64 maturity;
        uint64 repaymentDeadline;
        uint256 scaledBalance;
        address collateralToken;
        uint256 collateralTokenId;
    }

    mapping(bytes32 => StoredState) private _states;

    function set(
        bytes32 hash,
        LoanStatus status,
        uint64 maturity,
        uint64 repaymentDeadline,
        uint256 scaledBalance,
        address collateralToken_,
        uint256 collateralTokenId_
    ) external {
        _states[hash] = StoredState({
            status: status,
            maturity: maturity,
            repaymentDeadline: repaymentDeadline,
            scaledBalance: scaledBalance,
            collateralToken: collateralToken_,
            collateralTokenId: collateralTokenId_
        });
    }

    function loanTermsHash(
        LoanTerms calldata loanTerms
    ) external view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, loanTerms));
    }

    function loanState(
        bytes32 hash
    ) external view returns (LoanStatus status, uint64 maturity, uint64 repaymentDeadline, uint256 scaledBalance) {
        StoredState memory s = _states[hash];

        return (s.status, s.maturity, s.repaymentDeadline, s.scaledBalance);
    }

    function migrateOut(
        LoanTerms calldata loanTerms
    ) external {
        bytes32 hash = keccak256(abi.encode(block.chainid, loanTerms));

        StoredState storage s = _states[hash];

        IERC721(s.collateralToken).transferFrom(address(this), msg.sender, s.collateralTokenId);

        s.status = LoanStatus.Migrated;
    }
}

contract LoanRouterV2MigrateTest is RouterFixture {
    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    uint256 internal constant PRINCIPAL = 50_000_000 * 1e18;
    uint16 internal constant DURATION_DAYS = 365;

    /* USDC principal chosen so PRINCIPAL_USDC * 1e12 % 1e18 = 1e12 (non-zero dust) */
    uint256 internal constant PRINCIPAL_USDC = 50_000_000 * 1e6 + 1;
    uint256 internal constant SCALED_BALANCE_USDC = PRINCIPAL_USDC * 1e12;

    /*------------------------------------------------------------------------*/
    /* Deployed instances */
    /*------------------------------------------------------------------------*/

    LoanRouterV1Stub internal v1Stub;
    BundleCollateralWrapper internal bcw;
    LenderHookRecorder internal hookLender;

    /*------------------------------------------------------------------------*/
    /* Setup */
    /*------------------------------------------------------------------------*/

    function setUp() public override {
        super.setUp();

        v1Stub = new LoanRouterV1Stub();

        bcw = new BundleCollateralWrapper();

        hookLender = new LenderHookRecorder();

        /* Redeploy router with v1Stub wired as _loanRouterV1 */
        vm.startPrank(users.deployer);

        routerImpl = new LoanRouterV2(
            users.feeRecipient,
            address(collateralTimelock),
            address(depositTimelock),
            address(escrowTimelock),
            address(v1Stub)
        );

        routerProxy = new ERC1967Proxy(
            address(routerImpl), abi.encodeWithSelector(LoanRouterV2.initialize.selector, users.admin)
        );

        router = LoanRouterV2(address(routerProxy));

        vm.stopPrank();

        vm.startPrank(users.admin);

        IAccessControl(address(router)).grantRole(keccak256("ORIGINATOR_ROLE"), users.deployer);

        IAccessControl(address(router)).grantRole(keccak256("LIQUIDATOR_ROLE"), users.liquidator);

        IAccessControl(address(router)).grantRole(keccak256("PAUSE_ADMIN_ROLE"), users.admin);

        IAccessControl(address(router)).grantRole(keccak256("MIGRATOR_ROLE"), users.deployer);

        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Helpers */
    /*------------------------------------------------------------------------*/

    function _v1Terms(
        address collateralToken_,
        uint256 collateralTokenId_,
        bytes memory wrapperContext
    ) internal view returns (ILoanRouterV1.LoanTerms memory) {
        ILoanRouterV1.TrancheSpec[] memory tranches = new ILoanRouterV1.TrancheSpec[](1);

        tranches[0] = ILoanRouterV1.TrancheSpec({lender: users.lender1, amount: PRINCIPAL, rate: RATE_8_5_PCT});

        return ILoanRouterV1.LoanTerms({
            expiration: uint64(block.timestamp + 7 days),
            borrower: users.borrower,
            currencyToken: USDAI,
            collateralToken: collateralToken_,
            collateralTokenId: collateralTokenId_,
            duration: uint64(DURATION_DAYS) * 86400,
            repaymentInterval: 30 days,
            interestRateModel: address(irm),
            gracePeriodRate: 0,
            gracePeriodDuration: 0,
            feeSpec: ILoanRouterV1.FeeSpec({originationFee: 0, exitFee: 0}),
            trancheSpecs: tranches,
            collateralWrapperContext: wrapperContext,
            options: ""
        });
    }

    function _v2Terms() internal view returns (ILoanRouterV2.LoanTermsV2 memory) {
        ILoanRouterV2.TrancheSpec[] memory tranches = new ILoanRouterV2.TrancheSpec[](1);

        tranches[0] = ILoanRouterV2.TrancheSpec({lender: address(hookLender), amount: PRINCIPAL, rate: RATE_8_5_PCT});

        /* Placeholder collateral fields; overridden by computeMigration */
        uint256[] memory placeholderIds = new uint256[](1);

        return ILoanRouterV2.LoanTermsV2({
            expiration: uint64(block.timestamp + 7 days),
            borrower: users.borrower,
            currencyToken: USDAI,
            collateralToken: address(collateralNft),
            collateralTokenIds: placeholderIds,
            trancheSpecs: tranches,
            feeSpecs: new ILoanRouterV2.FeeSpec[](0),
            interestRateSpec: ILoanRouterV2.InterestRateSpec({
                model: address(irm),
                options: abi.encode(
                    SimpleInterestRateModel.Options({
                        gracePeriodDuration: 0, gracePeriodRate: 0, principalAndInterestStubPayment: true
                    })
                )
            }),
            repaymentSpec: ILoanRouterV2.RepaymentSpec({day: 1, totalDurationDays: 1, timezoneOffsetSeconds: 0}),
            approvalAddresses: new address[](0),
            options: ""
        });
    }

    /**
     * @dev Registers a loan in the V1 stub.
     *      maturityV1 = block.timestamp + DURATION_DAYS * 86400
     *      repaymentDeadlineV1 = block.timestamp + v1Terms.repaymentInterval (one fresh window ahead)
     */
    function _registerV1Loan(
        ILoanRouterV1.LoanTerms memory v1Terms,
        address collateralToken_,
        uint256 collateralTokenId_
    ) internal returns (bytes32 v1Hash, uint64 maturityV1, uint64 repaymentDeadlineV1) {
        v1Hash = v1Stub.loanTermsHash(v1Terms);

        maturityV1 = uint64(block.timestamp) + uint64(DURATION_DAYS) * 86400;

        repaymentDeadlineV1 = uint64(block.timestamp) + uint64(v1Terms.repaymentInterval);

        v1Stub.set(
            v1Hash,
            ILoanRouterV1.LoanStatus.Active,
            maturityV1,
            repaymentDeadlineV1,
            PRINCIPAL,
            collateralToken_,
            collateralTokenId_
        );
    }

    function _registerV1LoanFull(
        ILoanRouterV1.LoanTerms memory v1Terms,
        address collateralToken_,
        uint256 collateralTokenId_,
        uint64 maturityV1,
        uint64 repaymentDeadlineV1
    ) internal returns (bytes32 v1Hash) {
        v1Hash = v1Stub.loanTermsHash(v1Terms);

        v1Stub.set(
            v1Hash,
            ILoanRouterV1.LoanStatus.Active,
            maturityV1,
            repaymentDeadlineV1,
            PRINCIPAL,
            collateralToken_,
            collateralTokenId_
        );
    }

    function _mintCollateralToStub() internal returns (uint256 tokenId) {
        tokenId = nextCollateralId++;

        collateralNft.mint(address(v1Stub), tokenId);
    }

    function _mintBundleToStub()
        internal
        returns (uint256 bundleTokenId, uint256[] memory underlyingIds, bytes memory bundleContext)
    {
        underlyingIds = new uint256[](3);

        for (uint256 i; i < 3; i++) {
            underlyingIds[i] = nextCollateralId++;

            collateralNft.mint(users.deployer, underlyingIds[i]);
        }

        vm.startPrank(users.deployer);

        collateralNft.setApprovalForAll(address(bcw), true);

        bundleTokenId = bcw.mint(address(collateralNft), underlyingIds);

        vm.stopPrank();

        vm.prank(users.deployer);

        bcw.transferFrom(users.deployer, address(v1Stub), bundleTokenId);

        bundleContext = abi.encodePacked(address(collateralNft));

        for (uint256 i; i < 3; i++) {
            bundleContext = abi.encodePacked(bundleContext, underlyingIds[i]);
        }
    }

    function _registerV1LoanWithBalance(
        ILoanRouterV1.LoanTerms memory v1Terms,
        address collateralToken_,
        uint256 collateralTokenId_,
        uint256 scaledBalance
    ) internal returns (bytes32 v1Hash, uint64 maturityV1, uint64 repaymentDeadlineV1) {
        v1Hash = v1Stub.loanTermsHash(v1Terms);

        maturityV1 = uint64(block.timestamp) + uint64(DURATION_DAYS) * 86400;

        repaymentDeadlineV1 = uint64(block.timestamp) + uint64(v1Terms.repaymentInterval);

        v1Stub.set(
            v1Hash,
            ILoanRouterV1.LoanStatus.Active,
            maturityV1,
            repaymentDeadlineV1,
            scaledBalance,
            collateralToken_,
            collateralTokenId_
        );
    }

    function _v2TermsUsdc() internal view returns (ILoanRouterV2.LoanTermsV2 memory) {
        ILoanRouterV2.TrancheSpec[] memory tranches = new ILoanRouterV2.TrancheSpec[](1);

        tranches[0] =
            ILoanRouterV2.TrancheSpec({lender: address(hookLender), amount: PRINCIPAL_USDC, rate: RATE_8_5_PCT});

        uint256[] memory placeholderIds = new uint256[](1);

        return ILoanRouterV2.LoanTermsV2({
            expiration: uint64(block.timestamp + 7 days),
            borrower: users.borrower,
            currencyToken: USDC,
            collateralToken: address(collateralNft),
            collateralTokenIds: placeholderIds,
            trancheSpecs: tranches,
            feeSpecs: new ILoanRouterV2.FeeSpec[](0),
            interestRateSpec: ILoanRouterV2.InterestRateSpec({
                model: address(irm),
                options: abi.encode(
                    SimpleInterestRateModel.Options({
                        gracePeriodDuration: 0, gracePeriodRate: 0, principalAndInterestStubPayment: true
                    })
                )
            }),
            repaymentSpec: ILoanRouterV2.RepaymentSpec({day: 1, totalDurationDays: 1, timezoneOffsetSeconds: 0}),
            approvalAddresses: new address[](0),
            options: ""
        });
    }

    function _repayMigratedLoan(
        ILoanRouterV2.LoanTermsV2 memory loanTerms
    ) internal {
        (uint256 principalPayment, uint256 interestPayment, uint256 feePayment) = router.quote(loanTerms);

        uint256 totalPaid = principalPayment + interestPayment + feePayment;

        uint256 currentBalance = IERC20(loanTerms.currencyToken).balanceOf(users.borrower);

        if (currentBalance < totalPaid) {
            deal(loanTerms.currencyToken, users.borrower, currentBalance + totalPaid + 1e20);
        }

        vm.startPrank(users.borrower);

        IERC20(loanTerms.currencyToken).approve(address(router), totalPaid);

        router.repay(loanTerms, totalPaid);

        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: happy paths */
    /*------------------------------------------------------------------------*/

    /* Test: single-NFT collateral migration */
    function test_MigrateLoan_SingleNFT() public {
        uint256 nftId = _mintCollateralToStub();

        ILoanRouterV1.LoanTerms memory v1Terms = _v1Terms(address(collateralNft), nftId, "");

        (, uint64 maturityV1, uint64 repaymentDeadlineV1) = _registerV1Loan(v1Terms, address(collateralNft), nftId);

        /* lastPaidDeadlineV1 = repaymentDeadlineV1 - repaymentInterval */
        uint64 lastPaidDeadlineV1 = repaymentDeadlineV1 - uint64(v1Terms.repaymentInterval);

        uint16 durationDaysV2 = uint16((maturityV1 - lastPaidDeadlineV1) / 86400);

        uint256[] memory ids = new uint256[](1);

        ids[0] = nftId;

        ILoanRouterV2.LoanTermsV2 memory v2Terms = _v2Terms();

        v2Terms.repaymentSpec.totalDurationDays = durationDaysV2;

        v2Terms.collateralTokenIds = ids;

        vm.prank(users.deployer);

        router.migrateLoan(v1Terms, v2Terms, 0);

        bytes32 hashV2 = router.loanTermsHash(v2Terms);

        (ILoanRouterV2.LoanStatus status,, uint64 originationTs, uint256 scaledBalance) = router.loanState(hashV2);

        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active));

        assertEq(scaledBalance, PRINCIPAL);

        assertEq(originationTs, lastPaidDeadlineV1);

        assertEq(originationTs + uint64(v2Terms.repaymentSpec.totalDurationDays) * 86400, maturityV1);

        assertEq(collateralNft.ownerOf(nftId), address(router));

        bytes32 v1Hash = v1Stub.loanTermsHash(v1Terms);

        (ILoanRouterV1.LoanStatus v1Status,,,) = v1Stub.loanState(v1Hash);

        assertEq(uint8(v1Status), uint8(ILoanRouterV1.LoanStatus.Migrated));

        uint256[] memory positionIds = router.loanTokenIds(v2Terms);

        assertEq(positionIds.length, 1);

        assertEq(router.ownerOf(positionIds[0]), address(hookLender));
    }

    /* Test: BundleCollateralWrapper migration — bundle is unwrapped into individual V2 collateral IDs */
    function test_MigrateLoan_Bundle() public {
        (uint256 bundleTokenId, uint256[] memory underlyingIds, bytes memory bundleCtx) = _mintBundleToStub();

        ILoanRouterV1.LoanTerms memory v1Terms = _v1Terms(address(bcw), bundleTokenId, bundleCtx);

        (, uint64 maturityV1, uint64 repaymentDeadlineV1) = _registerV1Loan(v1Terms, address(bcw), bundleTokenId);

        uint64 lastPaidDeadlineV1 = repaymentDeadlineV1 - uint64(v1Terms.repaymentInterval);

        uint16 durationDaysV2 = uint16((maturityV1 - lastPaidDeadlineV1) / 86400);

        ILoanRouterV2.LoanTermsV2 memory v2Terms = _v2Terms();

        v2Terms.repaymentSpec.totalDurationDays = durationDaysV2;

        v2Terms.collateralTokenIds = underlyingIds;

        vm.prank(users.deployer);

        router.migrateLoan(v1Terms, v2Terms, 0);

        bytes32 hashV2 = router.loanTermsHash(v2Terms);

        (ILoanRouterV2.LoanStatus status,,, uint256 scaledBalance) = router.loanState(hashV2);

        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active));

        assertEq(scaledBalance, PRINCIPAL);

        assertFalse(bcw.exists(bundleTokenId));

        for (uint256 i; i < 3; i++) {
            assertEq(collateralNft.ownerOf(underlyingIds[i]), address(router));
        }

        uint256[] memory positionIds = router.loanTokenIds(v2Terms);

        assertEq(router.ownerOf(positionIds[0]), address(hookLender));
    }

    /* Test: V2 borrower need not match the V1 borrower */
    function test_MigrateLoan_BorrowerDiffersFromV1() public {
        uint256 nftId = _mintCollateralToStub();

        ILoanRouterV1.LoanTerms memory v1Terms = _v1Terms(address(collateralNft), nftId, "");

        (, uint64 maturityV1, uint64 repaymentDeadlineV1) = _registerV1Loan(v1Terms, address(collateralNft), nftId);

        uint64 lastPaidDeadlineV1 = repaymentDeadlineV1 - uint64(v1Terms.repaymentInterval);

        uint16 durationDaysV2 = uint16((maturityV1 - lastPaidDeadlineV1) / 86400);

        uint256[] memory ids = new uint256[](1);

        ids[0] = nftId;

        /* V2 borrower is a different address (e.g., a ReserveAccount) */
        ILoanRouterV2.LoanTermsV2 memory v2Terms = _v2Terms();

        v2Terms.repaymentSpec.totalDurationDays = durationDaysV2;

        v2Terms.collateralTokenIds = ids;

        v2Terms.borrower = makeAddr("reserveAccount");

        vm.prank(users.deployer);

        router.migrateLoan(v1Terms, v2Terms, 0);

        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(router.loanTermsHash(v2Terms));

        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active));
    }

    /* Test: LoanMigrated event emitted with correct hashes and borrower */
    function test_MigrateLoan_EmitsEvent() public {
        uint256 nftId = _mintCollateralToStub();

        ILoanRouterV1.LoanTerms memory v1Terms = _v1Terms(address(collateralNft), nftId, "");

        (bytes32 v1Hash, uint64 maturityV1, uint64 repaymentDeadlineV1) =
            _registerV1Loan(v1Terms, address(collateralNft), nftId);

        uint64 lastPaidDeadlineV1 = repaymentDeadlineV1 - uint64(v1Terms.repaymentInterval);

        uint16 durationDaysV2 = uint16((maturityV1 - lastPaidDeadlineV1) / 86400);

        uint256[] memory ids = new uint256[](1);

        ids[0] = nftId;

        ILoanRouterV2.LoanTermsV2 memory v2Terms = _v2Terms();

        v2Terms.repaymentSpec.totalDurationDays = durationDaysV2;

        v2Terms.collateralTokenIds = ids;

        bytes32 v2Hash = router.loanTermsHash(v2Terms);

        vm.expectEmit(true, true, true, true, address(router));

        emit ILoanRouterV2.LoanMigrated(v1Hash, v2Hash, abi.encode(v2Terms));

        vm.prank(users.deployer);

        router.migrateLoan(v1Terms, v2Terms, 0);
    }

    /* Test: migration succeeds when V1 loan is in grace period (past repayment deadline, before maturity) */
    function test_MigrateLoan_GracePeriod() public {
        uint256 nftId = _mintCollateralToStub();

        ILoanRouterV1.LoanTerms memory v1Terms = _v1Terms(address(collateralNft), nftId, "");

        /* Set repayment deadline in the past; maturity still in the future */
        _registerV1LoanFull(
            v1Terms,
            address(collateralNft),
            nftId,
            uint64(block.timestamp) + uint64(DURATION_DAYS) * 86400,
            uint64(block.timestamp) - 1
        );

        uint64 repaymentDeadlineV1 = uint64(block.timestamp) - 1;

        uint64 maturityV1 = uint64(block.timestamp) + uint64(DURATION_DAYS) * 86400;

        uint64 originationTimestampV1 = maturityV1 - uint64(v1Terms.duration);
        uint64 lastPaidDeadlineV1 = repaymentDeadlineV1 - uint64(v1Terms.repaymentInterval);
        if (lastPaidDeadlineV1 < originationTimestampV1) lastPaidDeadlineV1 = originationTimestampV1;

        uint16 durationDaysV2 = uint16((maturityV1 - lastPaidDeadlineV1) / 86400);

        uint256[] memory ids = new uint256[](1);

        ids[0] = nftId;

        ILoanRouterV2.LoanTermsV2 memory v2Terms = _v2Terms();

        v2Terms.repaymentSpec.totalDurationDays = durationDaysV2;

        v2Terms.collateralTokenIds = ids;

        vm.prank(users.deployer);

        router.migrateLoan(v1Terms, v2Terms, 0);

        /* Verify the loan was created as Active */
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(router.loanTermsHash(v2Terms));

        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active));
    }

    /*------------------------------------------------------------------------*/
    /* Test: revert — access control */
    /*------------------------------------------------------------------------*/

    /* Test: caller without MIGRATOR_ROLE reverts */
    function test_MigrateLoan_RevertWhen_NotMigrator() public {
        uint256 nftId = _mintCollateralToStub();

        ILoanRouterV1.LoanTerms memory v1Terms = _v1Terms(address(collateralNft), nftId, "");

        _registerV1Loan(v1Terms, address(collateralNft), nftId);

        vm.expectRevert();

        vm.prank(users.borrower);

        router.migrateLoan(v1Terms, _v2Terms(), 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: revert — V1 loan state */
    /*------------------------------------------------------------------------*/

    /* Test: V1 loan is not active */
    function test_MigrateLoan_RevertWhen_V1NotActive() public {
        uint256 nftId = _mintCollateralToStub();

        ILoanRouterV1.LoanTerms memory v1Terms = _v1Terms(address(collateralNft), nftId, "");

        bytes32 v1Hash = v1Stub.loanTermsHash(v1Terms);

        v1Stub.set(
            v1Hash,
            ILoanRouterV1.LoanStatus.Repaid,
            uint64(block.timestamp) + uint64(DURATION_DAYS) * 86400,
            uint64(block.timestamp) + 30 days,
            PRINCIPAL,
            address(collateralNft),
            nftId
        );

        vm.expectRevert(ILoanRouterV2.InvalidLoanState.selector);

        vm.prank(users.deployer);

        router.migrateLoan(v1Terms, _v2Terms(), 0);
    }

    /* Test: V1 loan is past maturity */
    function test_MigrateLoan_RevertWhen_PastMaturity() public {
        uint256 nftId = _mintCollateralToStub();

        ILoanRouterV1.LoanTerms memory v1Terms = _v1Terms(address(collateralNft), nftId, "");

        /* Set maturity to exactly now (>= block.timestamp triggers the revert) */
        _registerV1LoanFull(
            v1Terms, address(collateralNft), nftId, uint64(block.timestamp), uint64(block.timestamp) + 30 days
        );

        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Maturity"));

        vm.prank(users.deployer);

        router.migrateLoan(v1Terms, _v2Terms(), 0);
    }

    /* Test: borrower in LoanTermsV2 is zero address */
    function test_MigrateLoan_RevertWhen_ZeroBorrower() public {
        uint256 nftId = _mintCollateralToStub();

        ILoanRouterV1.LoanTerms memory v1Terms = _v1Terms(address(collateralNft), nftId, "");

        (, uint64 maturityV1, uint64 repaymentDeadlineV1) = _registerV1Loan(v1Terms, address(collateralNft), nftId);

        uint64 lastPaidDeadlineV1 = repaymentDeadlineV1 - uint64(v1Terms.repaymentInterval);

        uint16 durationDaysV2 = uint16((maturityV1 - lastPaidDeadlineV1) / 86400);

        uint256[] memory ids = new uint256[](1);

        ids[0] = nftId;

        ILoanRouterV2.LoanTermsV2 memory v2Terms = _v2Terms();

        v2Terms.repaymentSpec.totalDurationDays = durationDaysV2;

        v2Terms.collateralTokenIds = ids;

        v2Terms.borrower = address(0);

        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Borrower"));

        vm.prank(users.deployer);

        router.migrateLoan(v1Terms, v2Terms, 0);
    }

    /* Test: interestRateSpec.model in LoanTermsV2 is zero address */
    function test_MigrateLoan_RevertWhen_ZeroInterestRateModel() public {
        uint256 nftId = _mintCollateralToStub();

        ILoanRouterV1.LoanTerms memory v1Terms = _v1Terms(address(collateralNft), nftId, "");

        (, uint64 maturityV1, uint64 repaymentDeadlineV1) = _registerV1Loan(v1Terms, address(collateralNft), nftId);

        uint64 lastPaidDeadlineV1 = repaymentDeadlineV1 - uint64(v1Terms.repaymentInterval);

        uint16 durationDaysV2 = uint16((maturityV1 - lastPaidDeadlineV1) / 86400);

        uint256[] memory ids = new uint256[](1);

        ids[0] = nftId;

        ILoanRouterV2.LoanTermsV2 memory v2Terms = _v2Terms();

        v2Terms.repaymentSpec.totalDurationDays = durationDaysV2;

        v2Terms.collateralTokenIds = ids;

        v2Terms.interestRateSpec.model = address(0);

        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Interest Rate Model"));

        vm.prank(users.deployer);

        router.migrateLoan(v1Terms, v2Terms, 0);
    }

    /* Test: V1 repayment interval has a sub-day tail (not a whole multiple of 86400) */
    function test_MigrateLoan_RevertWhen_RepaymentIntervalNotMultipleOf1Day() public {
        uint256 nftId = _mintCollateralToStub();

        ILoanRouterV1.LoanTerms memory v1Terms = _v1Terms(address(collateralNft), nftId, "");

        /* 2592001 % 86400 = 1 != 0 */
        v1Terms.repaymentInterval = 30 days + 1;

        _registerV1Loan(v1Terms, address(collateralNft), nftId);

        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Repayment Interval"));

        vm.prank(users.deployer);

        router.migrateLoan(v1Terms, _v2Terms(), 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: repayment after migration */
    /*------------------------------------------------------------------------*/

    /* Test: migrate USDai loan then execute first and one middle repayment */
    function test_MigrateLoan_Repay_FirstAndMiddlePayments_USDai() public {
        uint256 nftId = _mintCollateralToStub();

        ILoanRouterV1.LoanTerms memory v1Terms = _v1Terms(address(collateralNft), nftId, "");

        (, uint64 maturityV1, uint64 repaymentDeadlineV1) = _registerV1Loan(v1Terms, address(collateralNft), nftId);

        uint64 lastPaidDeadlineV1 = repaymentDeadlineV1 - uint64(v1Terms.repaymentInterval);

        uint16 durationDaysV2 = uint16((maturityV1 - lastPaidDeadlineV1) / 86400);

        uint256[] memory ids = new uint256[](1);

        ids[0] = nftId;

        ILoanRouterV2.LoanTermsV2 memory v2Terms = _v2Terms();

        v2Terms.repaymentSpec.totalDurationDays = durationDaysV2;

        v2Terms.collateralTokenIds = ids;

        vm.prank(users.deployer);

        router.migrateLoan(v1Terms, v2Terms, 0);

        bytes32 hashV2 = router.loanTermsHash(v2Terms);

        (,, uint64 originationTs, uint256 balanceBefore) = router.loanState(hashV2);

        assertEq(balanceBefore, PRINCIPAL);

        uint64 deadline0 = _scheduleAt(v2Terms, originationTs)[0];

        uint64 deadline1 = _scheduleAt(v2Terms, originationTs)[1];

        /* First repayment */
        vm.warp(deadline0);

        (uint256 p1, uint256 i1,) = router.quote(v2Terms);

        /* USDai scaleFactor=1: interest = balance * rate * window / 1e18, rounded up */
        assertEq(i1, Math.mulDiv(PRINCIPAL * RATE_8_5_PCT, deadline0 - originationTs, 1e18, Math.Rounding.Ceil));

        /* principalAndInterestStubPayment is set for migrations, so the first payment amortizes principal instead of
        being a stub */
        assertGt(p1, 0, "Migrated first payment must amortize principal");

        _repayMigratedLoan(v2Terms);

        (, uint16 repaymentCount1,, uint256 balance1) = router.loanState(hashV2);

        assertEq(repaymentCount1, 1);

        /* USDai scaleFactor=1: quote principal == scaled principal, so balance drops by exactly p1 */
        assertEq(balance1, PRINCIPAL - p1);

        assertGt(balance1, 0);

        /* One middle repayment */
        vm.warp(deadline1);

        (uint256 p2, uint256 i2,) = router.quote(v2Terms);

        /* Interest on the reduced balance over the second window */
        assertEq(i2, Math.mulDiv(balance1 * RATE_8_5_PCT, deadline1 - deadline0, 1e18, Math.Rounding.Ceil));

        _repayMigratedLoan(v2Terms);

        (, uint16 repaymentCount2,, uint256 balance2) = router.loanState(hashV2);

        assertEq(repaymentCount2, 2);

        assertEq(balance2, balance1 - p2);
    }

    /*------------------------------------------------------------------------*/
    /* Test: revert — amortized V1 balance rejected by H-1 fix */
    /*------------------------------------------------------------------------*/

    /* Test: 18-decimal V1 balance one wei below V2 principal reverts */
    function test_MigrateLoan_RevertWhen_AmortizedBalance_USDai() public {
        uint256 nftId = _mintCollateralToStub();

        ILoanRouterV1.LoanTerms memory v1Terms = _v1Terms(address(collateralNft), nftId, "");

        /* One wei below the V2 principal triggers the equality check */
        (, uint64 maturityV1, uint64 repaymentDeadlineV1) =
            _registerV1LoanWithBalance(v1Terms, address(collateralNft), nftId, PRINCIPAL - 1);

        uint64 lastPaidDeadlineV1 = repaymentDeadlineV1 - uint64(v1Terms.repaymentInterval);

        uint16 durationDaysV2 = uint16((maturityV1 - lastPaidDeadlineV1) / 86400);

        uint256[] memory ids = new uint256[](1);

        ids[0] = nftId;

        ILoanRouterV2.LoanTermsV2 memory v2Terms = _v2Terms();

        v2Terms.repaymentSpec.totalDurationDays = durationDaysV2;

        v2Terms.collateralTokenIds = ids;

        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Principal"));

        vm.prank(users.deployer);

        router.migrateLoan(v1Terms, v2Terms, 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: migration origination fee paid to the lender hook */
    /*------------------------------------------------------------------------*/

    /* V2 terms carrying an Origination fee whose recipient is the tranche-0 lender (the hook contract) */
    function _v2TermsWithOriginationFee(
        uint256 feeAmount
    ) internal view returns (ILoanRouterV2.LoanTermsV2 memory terms) {
        terms = _v2Terms();

        ILoanRouterV2.FeeSpec[] memory fees = new ILoanRouterV2.FeeSpec[](1);

        fees[0] = ILoanRouterV2.FeeSpec({
            kind: ILoanRouterV2.FeeKind.Origination,
            recipient: terms.trancheSpecs[0].lender,
            model: address(absoluteFeeModel),
            options: abi.encode(AbsoluteFeeModel.Options({amount: feeAmount}))
        });

        terms.feeSpecs = fees;
    }

    /* Stage collateral, register the V1 loan, and migrate with the given V2 terms */
    function _migrateWith(
        ILoanRouterV2.LoanTermsV2 memory v2Terms
    ) internal returns (bytes32 hashV2) {
        uint256 nftId = _mintCollateralToStub();

        ILoanRouterV1.LoanTerms memory v1Terms = _v1Terms(address(collateralNft), nftId, "");

        (, uint64 maturityV1, uint64 repaymentDeadlineV1) = _registerV1Loan(v1Terms, address(collateralNft), nftId);

        uint64 lastPaidDeadlineV1 = repaymentDeadlineV1 - uint64(v1Terms.repaymentInterval);

        v2Terms.repaymentSpec.totalDurationDays = uint16((maturityV1 - lastPaidDeadlineV1) / 86400);

        uint256[] memory ids = new uint256[](1);

        ids[0] = nftId;

        v2Terms.collateralTokenIds = ids;

        vm.prank(users.deployer);

        router.migrateLoan(v1Terms, v2Terms, 0);

        hashV2 = router.loanTermsHash(v2Terms);
    }

    function test_MigrateLoan_OriginationFee_PaidToLenderHook() public {
        uint256 feeAmount = 100_000e18;

        /* The migrator sends the fee amount to the router before migrating */
        deal(USDAI, address(router), feeAmount);

        bytes32 hashV2 = _migrateWith(_v2TermsWithOriginationFee(feeAmount));

        /* The lender hook was notified with the origination fee details */
        assertTrue(hookLender.onLoanFeePaidCalled(), "onLoanFeePaid must fire");

        assertEq(uint8(hookLender.lastFeeKind()), uint8(ILoanRouterV2.FeeKind.Origination), "Fee kind is Origination");

        assertEq(hookLender.lastFeeModel(), address(absoluteFeeModel), "Fee model is the absolute fee model");

        assertEq(hookLender.lastFeeAmount(), feeAmount, "Fee amount matches the configured fee");

        /* The pre-sent fee moved from the router to the lender */
        assertEq(IERC20(USDAI).balanceOf(address(hookLender)), feeAmount, "Lender received the fee");

        assertEq(IERC20(USDAI).balanceOf(address(router)), 0, "Router forwarded the entire pre-sent fee");

        /* Migration still completed */
        (ILoanRouterV2.LoanStatus status,,, uint256 balance) = router.loanState(hashV2);

        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active));

        assertEq(balance, PRINCIPAL);
    }

    function test_MigrateLoan_NoOriginationFee_NoFeeHook() public {
        /* A migration without an Origination fee spec must not fire the fee hook */
        _migrateWith(_v2Terms());

        assertFalse(hookLender.onLoanFeePaidCalled(), "No fee spec means no fee hook");
    }

    function test_MigrateLoan_OriginationFee_RevertWhen_RouterNotPrefunded() public {
        uint256 feeAmount = 100_000e18;

        /* Router holds no currency, so paying the fee reverts the whole migration */
        uint256 nftId = _mintCollateralToStub();

        ILoanRouterV1.LoanTerms memory v1Terms = _v1Terms(address(collateralNft), nftId, "");

        (, uint64 maturityV1, uint64 repaymentDeadlineV1) = _registerV1Loan(v1Terms, address(collateralNft), nftId);

        uint64 lastPaidDeadlineV1 = repaymentDeadlineV1 - uint64(v1Terms.repaymentInterval);

        ILoanRouterV2.LoanTermsV2 memory v2Terms = _v2TermsWithOriginationFee(feeAmount);

        v2Terms.repaymentSpec.totalDurationDays = uint16((maturityV1 - lastPaidDeadlineV1) / 86400);

        uint256[] memory ids = new uint256[](1);

        ids[0] = nftId;

        v2Terms.collateralTokenIds = ids;

        vm.expectRevert();

        vm.prank(users.deployer);

        router.migrateLoan(v1Terms, v2Terms, 0);
    }
}
