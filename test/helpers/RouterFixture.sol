// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {BaseTest} from "../Base.t.sol";
import {LoanFixtures} from "./LoanFixtures.sol";
import {TestERC721} from "../mocks/TestERC721.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LoanRouterV2} from "src/LoanRouterV2.sol";
import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {ScheduleLogic} from "src/ScheduleLogic.sol";
import {SimpleInterestRateModel} from "src/rates/SimpleInterestRateModel.sol";
import {RatioFeeModel} from "src/fees/RatioFeeModel.sol";
import {AbsoluteFeeModel} from "src/fees/AbsoluteFeeModel.sol";

/**
 * @title RouterFixture
 * @author USD.AI Foundation
 */
abstract contract RouterFixture is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /**
     * $50M loan (raw 18dp USDai units)
     */
    uint256 internal constant LOAN_AMOUNT_USDAI = 50_000_000 * 1e18;
    /**
     * $50M loan (raw 6dp USDC units)
     */
    uint256 internal constant LOAN_AMOUNT_USDC = 50_000_000 * 1e6;

    /**
     * Half-and-half senior/junior split for the 2-tranche cases
     */
    uint256 internal constant TRANCHE_AMOUNT_HALF_USDAI = 25_000_000 * 1e18;
    uint256 internal constant TRANCHE_AMOUNT_HALF_USDC = 25_000_000 * 1e6;

    /**
     * Single-tranche default rate (the blended rate used for canonical loans)
     */
    /* RATE_8_5_PCT inherited from BaseTest */

    /**
     * Top-up so $50M loans + headroom comfortably fit on each lender / depositor
     */
    uint256 internal constant FUND_HEADROOM_USDAI = 200_000_000 * 1e18;
    uint256 internal constant FUND_HEADROOM_USDC = 200_000_000 * 1e6;

    /*------------------------------------------------------------------------*/
    /* Deployed instances */
    /*------------------------------------------------------------------------*/

    LoanRouterV2 internal router;
    LoanRouterV2 internal routerImpl;
    ERC1967Proxy internal routerProxy;

    SimpleInterestRateModel internal irm;
    RatioFeeModel internal ratioFeeModel;
    AbsoluteFeeModel internal absoluteFeeModel;

    TestERC721 internal collateralNft;
    address internal collateralDepositor;
    address internal insuranceRecipient;

    uint256 internal nextCollateralId;

    /*------------------------------------------------------------------------*/
    /* Setup */
    /*------------------------------------------------------------------------*/

    function setUp() public virtual override {
        super.setUp();

        /* Deploy router behind ERC1967Proxy */
        vm.startPrank(users.deployer);
        routerImpl = new LoanRouterV2(
            users.feeRecipient, address(collateralTimelock), address(depositTimelock), address(escrowTimelock)
        );
        routerProxy = new ERC1967Proxy(
            address(routerImpl), abi.encodeWithSelector(LoanRouterV2.initialize.selector, users.admin)
        );
        router = LoanRouterV2(address(routerProxy));
        vm.stopPrank();

        /* Grant roles */
        vm.startPrank(users.admin);
        IAccessControl(address(router)).grantRole(keccak256("ORIGINATOR_ROLE"), users.deployer);
        IAccessControl(address(router)).grantRole(keccak256("LIQUIDATOR_ROLE"), users.liquidator);
        IAccessControl(address(router)).grantRole(keccak256("PAUSE_ADMIN_ROLE"), users.admin);
        vm.stopPrank();

        /* Deploy IRM and fee models */
        irm = new SimpleInterestRateModel();
        ratioFeeModel = new RatioFeeModel();
        absoluteFeeModel = new AbsoluteFeeModel();

        /* Deploy collateral NFT */
        collateralNft = new TestERC721("Collateral", "COL");
        nextCollateralId = 1;

        /* Collateral depositor stages NFTs into CollateralTimelock before origination */
        collateralDepositor = makeAddr("collateralDepositor");

        /* Grant the collateral depositor deposit roles on the timelocks that use AccessControl */
        vm.startPrank(users.deployer);
        IAccessControl(address(depositTimelock)).grantRole(keccak256("ERC721_DEPOSITOR_ROLE"), collateralDepositor);
        IAccessControl(address(collateralTimelock)).grantRole(keccak256("DEPOSITOR_ROLE"), collateralDepositor);
        vm.stopPrank();

        /* Insurance recipient is a fresh address so balance deltas are clean */
        insuranceRecipient = makeAddr("insuranceRecipient");

        /* Top up balances for $50M loans */
        deal(USDAI, users.lender1, FUND_HEADROOM_USDAI);
        deal(USDAI, users.lender2, FUND_HEADROOM_USDAI);
        deal(USDAI, STAKED_USDAI, FUND_HEADROOM_USDAI);
        deal(USDAI, users.admin, FUND_HEADROOM_USDAI);
        deal(USDC, users.lender1, FUND_HEADROOM_USDC);
        deal(USDC, users.lender2, FUND_HEADROOM_USDC);

        /* DepositTimelock approvals were set in BaseTest. EscrowTimelock approvals (STAKED_USDAI → escrow,
         * admin → escrow) were also set in BaseTest. No additional approvals needed here. */
    }

    /*------------------------------------------------------------------------*/
    /* Loan-terms builders */
    /*------------------------------------------------------------------------*/

    struct LoanConfig {
        uint16 durationDays;
        LoanFixtures.WindowVariant variant;
        address currencyToken;
        bool twoTranches;
        bool useEscrowTimelock; /* single-tranche only — ignored when twoTranches=true */
        bool mixedDepositTypes; /* twoTranches=true only: tranche 0 EscrowTimelock, tranche 1 DepositTimelock */
        address[] approvalAddresses;
        ILoanRouterV2.FeeSpec[] feeSpecs;
        uint8 repaymentDay; /* 0 = use variant recipe's default */
        uint64 originationTimestamp; /* 0 = use variant recipe's default */
    }

    function buildLoanTerms(
        LoanConfig memory config
    ) internal returns (ILoanRouterV2.LoanTermsV2 memory loanTerms) {
        /* Apply variant defaults */
        (uint64 originationTs, uint8 recipeRepaymentDay) = LoanFixtures.windowVariantRecipe1095(config.variant);
        if (config.originationTimestamp == 0) config.originationTimestamp = originationTs;
        if (config.repaymentDay == 0) config.repaymentDay = recipeRepaymentDay;

        /* Build tranches */
        ILoanRouterV2.TrancheSpec[] memory tranches;
        if (config.twoTranches) {
            /* Senior + junior, 50/50 split, blends to 8.5% APR */
            uint256 trancheAmount = config.currencyToken == USDAI ? TRANCHE_AMOUNT_HALF_USDAI : TRANCHE_AMOUNT_HALF_USDC;
            address tranche0Lender = config.mixedDepositTypes ? STAKED_USDAI : users.lender1;
            tranches = LoanFixtures.tranches2(
                LoanFixtures.tranche(tranche0Lender, trancheAmount, RATE_8_PCT),
                LoanFixtures.tranche(users.lender2, trancheAmount, RATE_9_PCT)
            );
        } else {
            /* Single tranche, full $50M, 8.5% APR */
            uint256 fullAmount = config.currencyToken == USDAI ? LOAN_AMOUNT_USDAI : LOAN_AMOUNT_USDC;
            address lender = config.useEscrowTimelock ? STAKED_USDAI : users.lender1;
            tranches = LoanFixtures.tranches1(LoanFixtures.tranche(lender, fullAmount, RATE_8_5_PCT));
        }

        /* Mint a collateral NFT to the depositor who will stage it in CollateralTimelock */
        uint256 tokenId = nextCollateralId++;
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        collateralNft.mint(collateralDepositor, tokenId);

        /* IRM options: no grace period (tests pass timestamps at deadlines) */
        bytes memory irmOpts = abi.encode(
            SimpleInterestRateModel.Options({
                gracePeriodDuration: 0, gracePeriodRate: 0, principalAndInterestStubPayment: false
            })
        );

        /* Assemble */
        loanTerms = ILoanRouterV2.LoanTermsV2({
            expiration: uint64(config.originationTimestamp + 7 days),
            borrower: users.borrower,
            currencyToken: config.currencyToken,
            collateralToken: address(collateralNft),
            collateralTokenIds: tokenIds,
            trancheSpecs: tranches,
            feeSpecs: config.feeSpecs,
            interestRateSpec: ILoanRouterV2.InterestRateSpec({model: address(irm), options: irmOpts}),
            repaymentSpec: ILoanRouterV2.RepaymentSpec({
                day: config.repaymentDay, totalDurationDays: config.durationDays, timezoneOffsetSeconds: 0
            }),
            approvalAddresses: config.approvalAddresses,
            options: ""
        });
    }

    /*------------------------------------------------------------------------*/
    /* Origination helpers */
    /*------------------------------------------------------------------------*/

    function originateLoan(
        ILoanRouterV2.LoanTermsV2 memory loanTerms,
        ILoanRouterV2.LenderDepositInfo[] memory infos,
        bytes[] memory signatures
    ) internal returns (uint256) {
        vm.prank(users.deployer);
        return router.originate(loanTerms, infos, signatures);
    }

    function prepareLenderDeposits(
        ILoanRouterV2.LoanTermsV2 memory loanTerms,
        bool tranche0UsesEscrow
    ) internal {
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        uint64 expiration = uint64(block.timestamp + 7 days);
        for (uint8 i = 0; i < loanTerms.trancheSpecs.length; i++) {
            ILoanRouterV2.TrancheSpec memory t = loanTerms.trancheSpecs[i];
            bool useEscrow = (i == 0) ? tranche0UsesEscrow : false;
            if (useEscrow) {
                /* EscrowTimelock deposit (must be from STAKED_USDAI, the _escrowERC20Depositor) */
                vm.prank(STAKED_USDAI);
                escrowTimelock.deposit(
                    address(router),
                    loanTermsHash_,
                    address(USDAI),
                    t.amount,
                    0 /* interestRate */
                );
            } else {
                /* DepositTimelock deposit (from t.lender) */
                vm.prank(t.lender);
                depositTimelock.deposit(address(router), loanTermsHash_, loanTerms.currencyToken, t.amount, expiration);
            }
        }
    }

    function prepareCollateralDeposit(
        ILoanRouterV2.LoanTermsV2 memory loanTerms
    ) internal {
        /* Context is the loan terms hash the router withdraws against */
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);

        /* Approve collateralTimelock and stage the collateral keyed to the router and hash */
        vm.startPrank(collateralDepositor);
        collateralNft.setApprovalForAll(address(collateralTimelock), true);
        uint64 expiration = uint64(block.timestamp + 7 days);
        collateralTimelock.deposit(
            address(router), loanTermsHash_, address(collateralNft), loanTerms.collateralTokenIds, expiration
        );
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Schedule helpers */
    /*------------------------------------------------------------------------*/

    function _schedule(
        ILoanRouterV2.LoanTermsV2 memory loanTerms
    ) internal view returns (uint64[] memory deadlines) {
        /* Read the router's deadline schedule */
        deadlines = router.deadlines(loanTerms);
    }

    function _scheduleAt(
        ILoanRouterV2.LoanTermsV2 memory loanTerms,
        uint64 originationTimestamp
    ) internal pure returns (uint64[] memory deadlines) {
        /* Drop the stub flag from the computed deadline schedule */
        (, deadlines) = ScheduleLogic.deadlines(loanTerms, originationTimestamp);
    }

    function _repayAt(
        ILoanRouterV2.LoanTermsV2 memory loanTerms,
        uint64 timestamp
    ) internal {
        /* Warp to the repayment time and quote the amount due */
        vm.warp(timestamp);

        (uint256 principalPayment, uint256 interestPayment, uint256 feePayment) = router.quote(loanTerms);

        uint256 totalDue = principalPayment + interestPayment + feePayment;

        /* Nothing to do when the quote is zero */
        if (totalDue == 0) return;

        /* Fund the borrower and repay */
        deal(loanTerms.currencyToken, users.borrower, totalDue + 1e20);

        vm.startPrank(users.borrower);

        IERC20(loanTerms.currencyToken).approve(address(router), totalDue);

        router.repay(loanTerms, totalDue);

        vm.stopPrank();
    }

    function buildDepositInfos(
        ILoanRouterV2.LoanTermsV2 memory loanTerms,
        bool tranche0UsesEscrow
    ) internal pure returns (ILoanRouterV2.LenderDepositInfo[] memory infos) {
        infos = new ILoanRouterV2.LenderDepositInfo[](loanTerms.trancheSpecs.length);
        for (uint8 i = 0; i < loanTerms.trancheSpecs.length; i++) {
            bool useEscrow = (i == 0) ? tranche0UsesEscrow : false;
            infos[i] = ILoanRouterV2.LenderDepositInfo({
                depositType: useEscrow
                    ? ILoanRouterV2.DepositType.EscrowTimelock
                    : ILoanRouterV2.DepositType.DepositTimelock,
                data: ""
            });
        }
    }

    /*------------------------------------------------------------------------*/
    /* One-shot canonical originations */
    /*------------------------------------------------------------------------*/

    function originateDefault() internal returns (ILoanRouterV2.LoanTermsV2 memory loanTerms) {
        return originateConfigured(_defaultConfig());
    }

    function _defaultConfig() internal view returns (LoanConfig memory config) {
        config.durationDays = 1095;
        config.variant = LoanFixtures.WindowVariant.Upper;
        config.currencyToken = USDAI;
        config.twoTranches = false;
        config.useEscrowTimelock = true;
        config.feeSpecs = new ILoanRouterV2.FeeSpec[](0);
        config.approvalAddresses = new address[](0);
    }

    function originateConfigured(
        LoanConfig memory config
    ) internal returns (ILoanRouterV2.LoanTermsV2 memory loanTerms) {
        loanTerms = buildLoanTerms(config);
        vm.warp(config.originationTimestamp == 0 ? _recipeTimestamp(config.variant) : config.originationTimestamp);

        bool tranche0UsesEscrow = config.twoTranches ? config.mixedDepositTypes : config.useEscrowTimelock;
        prepareLenderDeposits(loanTerms, tranche0UsesEscrow);
        prepareCollateralDeposit(loanTerms);
        ILoanRouterV2.LenderDepositInfo[] memory infos = buildDepositInfos(loanTerms, tranche0UsesEscrow);
        originateLoan(loanTerms, infos, new bytes[](0));
    }

    function _recipeTimestamp(
        LoanFixtures.WindowVariant variant
    ) internal pure returns (uint64 ts) {
        (ts,) = LoanFixtures.windowVariantRecipe1095(variant);
    }

    /*------------------------------------------------------------------------*/
    /* EIP-712 approval signature helper */
    /*------------------------------------------------------------------------*/

    bytes32 internal constant LOAN_TERMS_APPROVAL_TYPEHASH = keccak256("LoanTermsApproval(bytes32 loanTermsHash)");

    function _approvalDigest(
        bytes32 loanTermsHash_
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(LOAN_TERMS_APPROVAL_TYPEHASH, loanTermsHash_));
        return MessageHashUtils.toTypedDataHash(_routerDomainSeparator(), structHash);
    }

    function signLoanTermsApproval(
        uint256 privateKey,
        bytes32 loanTermsHash_
    ) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, _approvalDigest(loanTermsHash_));
        return abi.encodePacked(r, s, v);
    }

    function _routerDomainSeparator() internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            LoanRouterV2(address(router)).eip712Domain();
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
    }
}
