// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {LoanRouter} from "src/LoanRouter.sol";
import {DepositTimelock} from "src/DepositTimelock.sol";
import {EscrowTimelock} from "src/EscrowTimelock.sol";
import {CollateralTimelock} from "src/CollateralTimelock.sol";
import {BundleCollateralWrapper} from "src/collateralWrappers/BundleCollateralWrapper.sol";
import {AmortizedInterestRateModel} from "src/rates/AmortizedInterestRateModel.sol";
import {LoanTermsLogic} from "src/LoanTermsLogic.sol";
import {ILoanRouter} from "src/interfaces/ILoanRouter.sol";

import {TestERC721} from "./mocks/TestERC721.sol";
import {ExternalCollateralLiquidator} from "src/liquidators/ExternalCollateralLiquidator.sol";

/**
 * @title Base test setup for LoanRouter
 * @author USD.AI Foundation
 */
abstract contract BaseTest is Test {
    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /* Arbitrum Mainnet addresses */
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address internal constant USDAI = 0x0A1a1A107E45b7Ced86833863f482BC5f4ed82EF;
    address internal constant STAKED_USDAI = 0x0B2b2B2076d95dda7817e785989fE353fe955ef9;
    address internal constant UNISWAP_V3_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    /* Time constants */
    uint64 internal constant LOAN_DURATION = 1080 days; // 3 years - 5 days
    uint64 internal constant REPAYMENT_INTERVAL = 30 days;
    uint64 internal constant GRACE_PERIOD_DURATION = 30 days;

    /* Rate constants (per second) */
    // 5% per annum = 0.05 / (365 * 86400) = ~1.585e-9 per second
    uint256 internal constant GRACE_PERIOD_RATE = 1585489599; // 5% APR in per-second rate (scaled by 1e18)

    // Interest rates for tranches (per second, scaled by 1e18)
    // To get 10-12% APR weighted average
    // 8% APR = ~2.537e-9 per second = 2537174559 (scaled by 1e18)
    // 10% APR = ~3.171e-9 per second = 3171469679 (scaled by 1e18)
    // 12% APR = ~3.806e-9 per second = 3805763799 (scaled by 1e18)
    // 14% APR = ~4.440e-9 per second = 4440057919 (scaled by 1e18)
    uint256 internal constant RATE_8_PCT = 2537174559;
    uint256 internal constant RATE_10_PCT = 3171469679;
    uint256 internal constant RATE_12_PCT = 3805763799;
    uint256 internal constant RATE_14_PCT = 4440057919;

    /* Fixed point scale */
    uint256 internal constant FIXED_POINT_SCALE = 1e18;

    /* Number of token IDs to wrap */
    uint256 internal constant NUM_TOKEN_IDS = 128;

    /* Liquidation fee rate (10%) */
    uint256 internal constant LIQUIDATION_FEE_RATE = 1000;

    /*------------------------------------------------------------------------*/
    /* User accounts */
    /*------------------------------------------------------------------------*/

    struct Users {
        address payable deployer;
        address payable admin;
        address payable feeRecipient;
        address payable borrower;
        address payable lender1;
        address payable lender2;
        address payable lender3;
        address payable liquidator;
    }

    Users internal users;

    /*------------------------------------------------------------------------*/
    /* Contract instances */
    /*------------------------------------------------------------------------*/

    BundleCollateralWrapper internal bundleCollateralWrapper;
    ExternalCollateralLiquidator internal externalCollateralLiquidator;

    LoanRouter internal loanRouterImpl;
    LoanRouter internal loanRouter;
    TransparentUpgradeableProxy internal loanRouterProxy;

    DepositTimelock internal depositTimelockImpl;
    DepositTimelock internal depositTimelock;
    TransparentUpgradeableProxy internal depositTimelockProxy;

    EscrowTimelock internal escrowTimelockImpl;
    EscrowTimelock internal escrowTimelock;
    TransparentUpgradeableProxy internal escrowTimelockProxy;

    CollateralTimelock internal collateralTimelockImpl;
    CollateralTimelock internal collateralTimelock;
    TransparentUpgradeableProxy internal collateralTimelockProxy;

    AmortizedInterestRateModel internal interestRateModel;

    TestERC721 internal testNFT;

    /*------------------------------------------------------------------------*/
    /* Test state */
    /*------------------------------------------------------------------------*/

    uint256 internal wrappedTokenId;
    uint256[] internal tokenIdsToWrap;
    bytes internal encodedBundle;

    /*------------------------------------------------------------------------*/
    /* Setup */
    /*------------------------------------------------------------------------*/

    function setUp() public virtual {
        // Fork Arbitrum mainnet
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"));
        vm.rollFork(401947600);

        // Create users
        users = Users({
            deployer: createUser("deployer"),
            admin: createUser("admin"),
            feeRecipient: createUser("feeRecipient"),
            borrower: createUser("borrower"),
            lender1: createUser("lender1"),
            lender2: createUser("lender2"),
            lender3: createUser("lender3"),
            liquidator: createUser("liquidator")
        });

        // Deploy test NFT
        deployTestNFT();

        // Deploy bundle collateral wrapper
        deployBundleCollateralWrapper();

        // Deploy external collateral liquidator
        deployExternalCollateralLiquidator();

        // Deploy contracts
        deployDepositTimelock();
        deployEscrowTimelock();
        deployCollateralTimelock();

        // Setup
        setupCollateralWrapper();
        fundUsers();
        setApprovals();
    }

    /*------------------------------------------------------------------------*/
    /* Deployment functions */
    /*------------------------------------------------------------------------*/

    function deployDepositTimelock() internal {
        vm.startPrank(users.deployer);

        // Deploy implementation
        depositTimelockImpl = new DepositTimelock();

        // Deploy proxy
        depositTimelockProxy = new TransparentUpgradeableProxy(
            address(depositTimelockImpl),
            address(users.admin),
            abi.encodeWithSignature("initialize(address)", users.deployer)
        );

        // Create interface
        depositTimelock = DepositTimelock(address(depositTimelockProxy));

        // Grant ERC20 depositor role to lenders
        AccessControl(address(depositTimelock)).grantRole(keccak256("DEPOSITOR_ROLE"), users.lender1);
        AccessControl(address(depositTimelock)).grantRole(keccak256("DEPOSITOR_ROLE"), users.lender2);

        vm.stopPrank();
    }

    function deployEscrowTimelock() internal {
        vm.startPrank(users.deployer);

        // Deploy proxy
        escrowTimelockImpl = new EscrowTimelock(USDAI, STAKED_USDAI, users.admin);
        escrowTimelockProxy = new TransparentUpgradeableProxy(
            address(escrowTimelockImpl),
            address(users.admin),
            abi.encodeWithSignature("initialize(address)", users.deployer)
        );

        // Create interface
        escrowTimelock = EscrowTimelock(address(escrowTimelockProxy));

        vm.stopPrank();
    }

    function deployCollateralTimelock() internal {
        vm.startPrank(users.deployer);

        // Deploy implementation
        collateralTimelockImpl = new CollateralTimelock();

        // Deploy proxy
        collateralTimelockProxy = new TransparentUpgradeableProxy(
            address(collateralTimelockImpl),
            address(users.admin),
            abi.encodeWithSignature("initialize(address)", users.deployer)
        );

        // Create interface
        collateralTimelock = CollateralTimelock(address(collateralTimelockProxy));

        // Grant ERC721 depositor role to depositors
        AccessControl(address(collateralTimelock)).grantRole(keccak256("DEPOSITOR_ROLE"), users.borrower);
        AccessControl(address(collateralTimelock)).grantRole(keccak256("DEPOSITOR_ROLE"), users.lender1);

        vm.stopPrank();
    }

    function deployLoanRouter() internal {
        vm.startPrank(users.deployer);

        // Deploy implementation
        loanRouterImpl = new LoanRouter(
            address(depositTimelock), address(externalCollateralLiquidator), address(bundleCollateralWrapper)
        );

        // Deploy proxy
        loanRouterProxy = new TransparentUpgradeableProxy(
            address(loanRouterImpl),
            address(users.admin),
            abi.encodeWithSignature(
                "initialize(address,address,uint256)", users.deployer, users.feeRecipient, LIQUIDATION_FEE_RATE
            )
        );

        // Create interface
        loanRouter = LoanRouter(address(loanRouterProxy));

        vm.stopPrank();
    }

    function deployInterestRateModel() internal {
        vm.startPrank(users.deployer);
        interestRateModel = new AmortizedInterestRateModel();
        vm.stopPrank();
    }

    function deployTestNFT() internal {
        vm.startPrank(users.deployer);
        testNFT = new TestERC721("TestNFT", "TNFT");
        vm.stopPrank();
    }

    function deployBundleCollateralWrapper() internal {
        vm.startPrank(users.deployer);
        bundleCollateralWrapper = new BundleCollateralWrapper();
        vm.stopPrank();
    }

    function deployExternalCollateralLiquidator() internal {
        vm.startPrank(users.deployer);
        ExternalCollateralLiquidator externalCollateralLiquidatorImpl = new ExternalCollateralLiquidator();
        externalCollateralLiquidator = ExternalCollateralLiquidator(
            address(
                new TransparentUpgradeableProxy(
                    address(externalCollateralLiquidatorImpl),
                    address(users.admin),
                    abi.encodeWithSignature("initialize(address)", users.admin)
                )
            )
        );
        vm.stopPrank();

        vm.prank(users.admin);
        AccessControl(address(externalCollateralLiquidator))
            .grantRole(keccak256("COLLATERAL_LIQUIDATOR"), users.liquidator);
    }

    /*------------------------------------------------------------------------*/
    /* Setup functions */
    /*------------------------------------------------------------------------*/

    function setupCollateralWrapper() internal {
        // Mint NFTs to borrower
        vm.startPrank(users.deployer);

        // Create array of token IDs to wrap
        tokenIdsToWrap = new uint256[](NUM_TOKEN_IDS);
        for (uint256 i = 0; i < NUM_TOKEN_IDS; i++) {
            uint256 tokenId = 1000 + i;
            testNFT.mint(users.borrower, tokenId);
            tokenIdsToWrap[i] = tokenId;
        }

        vm.stopPrank();

        // Wrap NFTs in collateral wrapper
        vm.startPrank(users.borrower);

        // Approve collateral wrapper to transfer NFTs
        testNFT.setApprovalForAll(address(bundleCollateralWrapper), true);

        // Record logs to capture BundleMinted event
        vm.recordLogs();

        // Mint bundle (wrap NFTs)
        (bool success, bytes memory data) = address(bundleCollateralWrapper)
            .call(abi.encodeWithSignature("mint(address,uint256[])", address(testNFT), tokenIdsToWrap));
        require(success, "Failed to mint bundle");

        // Decode wrapped token ID
        wrappedTokenId = abi.decode(data, (uint256));

        // Get the BundleMinted event and extract encodedBundle
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // BundleMinted event is: event BundleMinted(uint256 indexed tokenId, address indexed minter, bytes
        // encodedBundle)
        // The encodedBundle is the third parameter (not indexed)
        for (uint256 i = 0; i < logs.length; i++) {
            // BundleMinted event signature
            if (logs[i].topics[0] == keccak256("BundleMinted(uint256,address,bytes)")) {
                // Decode the encodedBundle from event data
                encodedBundle = abi.decode(logs[i].data, (bytes));
                break;
            }
        }

        require(encodedBundle.length > 0, "Failed to capture encodedBundle from event");

        vm.stopPrank();
    }

    function fundUsers() internal {
        // Use deal to give everyone USDC and USDai directly
        deal(USDC, users.borrower, 1_000_000 * 1e6); // 1M USDC
        deal(USDC, users.lender1, 10_000_000 * 1e6); // 10M USDC
        deal(USDC, users.lender2, 10_000_000 * 1e6); // 10M USDC
        deal(USDC, users.lender3, 10_000_000 * 1e6); // 10M USDC

        // Give lenders USDai using deal()
        deal(USDAI, users.lender1, 10_000_000 * 1e18); // 10M USDai
        deal(USDAI, users.lender2, 10_000_000 * 1e18); // 10M USDai
        deal(USDAI, users.lender3, 10_000_000 * 1e18); // 10M USDai

        // Give lenders USDT using deal()
        deal(USDT, users.lender1, 10_000_000 * 1e6); // 10M USDT
        deal(USDT, users.lender2, 10_000_000 * 1e6); // 10M USDT
        deal(USDT, users.lender3, 10_000_000 * 1e6); // 10M USDT

        // Fund sUSDai and escrow admin for EscrowTimelock tests
        deal(USDAI, STAKED_USDAI, 10_000_000 * 1e18); // 10M USDai for sUSDai
        deal(USDAI, users.admin, 100_000_000 * 1e18); // 100M USDai for escrow admin (covers interest)
    }

    function setApprovals() internal {
        // Borrower approvals
        vm.startPrank(users.borrower);
        IERC721(bundleCollateralWrapper).setApprovalForAll(address(loanRouter), true);
        IERC20(USDC).approve(address(loanRouter), type(uint256).max);
        vm.stopPrank();

        // Lender approvals
        address[] memory lenders = new address[](3);
        lenders[0] = users.lender1;
        lenders[1] = users.lender2;
        lenders[2] = users.lender3;

        for (uint256 i = 0; i < lenders.length; i++) {
            vm.startPrank(lenders[i]);
            IERC20(USDC).approve(address(loanRouter), type(uint256).max);
            IERC20(USDC).approve(address(depositTimelock), type(uint256).max);
            IERC20(USDAI).approve(address(depositTimelock), type(uint256).max);
            IERC20(USDT).approve(address(depositTimelock), type(uint256).max);
            vm.stopPrank();
        }

        // sUSDai approves EscrowTimelock to spend its USDai (for deposits)
        vm.prank(STAKED_USDAI);
        IERC20(USDAI).approve(address(escrowTimelock), type(uint256).max);

        // Escrow admin approves EscrowTimelock to spend its USDai (for cancel/withdraw interest)
        vm.prank(users.admin);
        IERC20(USDAI).approve(address(escrowTimelock), type(uint256).max);

        // Mock sUSDai to accept ERC721 receipt tokens (forked contract may not implement IERC721Receiver)
        vm.mockCall(
            STAKED_USDAI,
            abi.encodeWithSelector(IERC721Receiver.onERC721Received.selector),
            abi.encode(IERC721Receiver.onERC721Received.selector)
        );
    }

    /*------------------------------------------------------------------------*/
    /* Helper functions */
    /*------------------------------------------------------------------------*/

    function createUser(
        string memory name
    ) internal returns (address payable addr) {
        addr = payable(makeAddr(name));
        vm.label({account: addr, newLabel: name});
        vm.deal({account: addr, newBalance: 100 ether});
    }

    function _createLoanTerms(
        address borrower_,
        uint256 principal,
        uint256 numTranches,
        uint256 originationFee,
        uint256 exitFee,
        address interestRateModel_
    ) internal view returns (ILoanRouter.LoanTerms memory) {
        require(numTranches > 0 && numTranches <= 3, "Invalid number of tranches");

        ILoanRouter.TrancheSpec[] memory trancheSpecs = new ILoanRouter.TrancheSpec[](numTranches);

        // Distribute principal equally among tranches
        uint256 amountPerTranche = principal / numTranches;
        uint256 remainingPrincipal = principal;

        // Create tranches with increasing rates to ensure weighted average is 10-12% APR
        address[] memory lenders = new address[](3);
        lenders[0] = users.lender1;
        lenders[1] = users.lender2;
        lenders[2] = users.lender3;

        uint256[] memory rates = new uint256[](3);
        if (numTranches == 1) {
            rates[0] = RATE_10_PCT; // 10% APR
        } else if (numTranches == 2) {
            rates[0] = RATE_8_PCT; // 8% APR
            rates[1] = RATE_12_PCT; // 12% APR (weighted average: ~10%)
        } else {
            // numTranches == 3
            rates[0] = RATE_8_PCT; // 8% APR
            rates[1] = RATE_10_PCT; // 10% APR
            rates[2] = RATE_14_PCT; // 14% APR (weighted average: ~10.67%)
        }

        for (uint256 i = 0; i < numTranches; i++) {
            uint256 amount = (i == numTranches - 1) ? remainingPrincipal : amountPerTranche;
            remainingPrincipal -= amount;

            trancheSpecs[i] = ILoanRouter.TrancheSpec({lender: lenders[i], amount: amount, rate: rates[i]});
        }

        return ILoanRouter.LoanTerms({
            expiration: uint64(block.timestamp + 7 days),
            borrower: borrower_,
            currencyToken: USDC,
            collateralToken: address(bundleCollateralWrapper),
            collateralTokenId: wrappedTokenId,
            duration: LOAN_DURATION,
            repaymentInterval: REPAYMENT_INTERVAL,
            interestRateModel: interestRateModel_,
            gracePeriodRate: GRACE_PERIOD_RATE,
            gracePeriodDuration: uint256(GRACE_PERIOD_DURATION),
            feeSpec: ILoanRouter.FeeSpec({originationFee: originationFee, exitFee: exitFee}),
            trancheSpecs: trancheSpecs,
            collateralWrapperContext: encodedBundle,
            options: ""
        });
    }

    function createLoanTerms(
        address borrower_,
        uint256 principal,
        uint256 numTranches,
        uint256 originationFee,
        uint256 exitFee
    ) internal view returns (ILoanRouter.LoanTerms memory) {
        return _createLoanTerms(borrower_, principal, numTranches, originationFee, exitFee, address(interestRateModel));
    }

    function createLoanTerms(
        address borrower_,
        uint256 principal,
        uint256 numTranches,
        uint256 originationFee,
        uint256 exitFee,
        address interestRateModel_
    ) internal view returns (ILoanRouter.LoanTerms memory) {
        return _createLoanTerms(borrower_, principal, numTranches, originationFee, exitFee, interestRateModel_);
    }

    function signLoanTerms(
        ILoanRouter.LoanTerms memory loanTerms,
        uint256 lenderPrivateKey,
        uint256 nonce
    ) internal view returns (bytes memory) {
        // Compute domain separator for EIP-712
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("USDai Loan Router")),
                keccak256(bytes("1.0")),
                block.chainid,
                address(loanRouter)
            )
        );

        // Use LenderSignatureLogic to properly encode the loan terms with nonce
        // Convert memory to calldata by using a temporary variable
        ILoanRouter.LoanTerms[] memory loanTermsArray = new ILoanRouter.LoanTerms[](1);
        loanTermsArray[0] = loanTerms;

        // Encode using the proper library function
        bytes32 structHash = this.encodeLenderSignatureExternal(loanTerms, nonce);

        // Create EIP-712 hash manually
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(lenderPrivateKey, digest);

        bytes memory loanTermsSignature = abi.encodePacked(r, s, v);

        return loanTermsSignature;
    }

    /**
     * @notice Create LenderDepositInfo array for DepositTimelock funding
     * @param numTranches Number of tranches
     * @return LenderDepositInfo array with DepositTimelock type
     */
    function createDepositTimelockInfos(
        uint256 numTranches
    ) internal pure returns (ILoanRouter.LenderDepositInfo[] memory) {
        ILoanRouter.LenderDepositInfo[] memory infos = new ILoanRouter.LenderDepositInfo[](numTranches);
        for (uint256 i = 0; i < numTranches; i++) {
            infos[i] = ILoanRouter.LenderDepositInfo({
                depositType: ILoanRouter.DepositType.DepositTimelock,
                data: "" // Empty swap data for USDai -> USDC
            });
        }
        return infos;
    }

    /**
     * @notice Create LenderDepositInfo array for DepositTimelock funding with Uniswap swap adapter
     * @param numTranches Number of tranches
     * @return LenderDepositInfo array with DepositTimelock type
     */
    function createDepositTimelockInfosUniswap(
        uint256 numTranches
    ) internal pure returns (ILoanRouter.LenderDepositInfo[] memory) {
        ILoanRouter.LenderDepositInfo[] memory infos = new ILoanRouter.LenderDepositInfo[](numTranches);
        for (uint256 i = 0; i < numTranches; i++) {
            infos[i] = ILoanRouter.LenderDepositInfo({
                depositType: ILoanRouter.DepositType.DepositTimelock,
                data: abi.encodePacked(address(USDC), uint24(100), address(USDT)) // Empty swap data for USDai -> USDC
            });
        }
        return infos;
    }

    /**
     * @notice Create LenderDepositInfo for ERC20Approval funding
     * @param signature The signature bytes
     * @return LenderDepositInfo with ERC20Approval type
     */
    function createERC20ApprovalInfo(
        bytes memory signature
    ) internal pure returns (ILoanRouter.LenderDepositInfo memory) {
        return ILoanRouter.LenderDepositInfo({depositType: ILoanRouter.DepositType.ERC20Approval, data: signature});
    }

    /**
     * @notice Create LenderDepositInfo for ERC20Permit funding
     * @param signature The signature bytes with permit data
     * @return LenderDepositInfo with ERC20Permit type
     */
    function createERC20PermitInfo(
        bytes memory signature
    ) internal pure returns (ILoanRouter.LenderDepositInfo memory) {
        return ILoanRouter.LenderDepositInfo({depositType: ILoanRouter.DepositType.ERC20Permit, data: signature});
    }

    function signLoanTermsWithPermit(
        ILoanRouter.LoanTerms memory loanTerms,
        uint256 lenderPrivateKey,
        uint256 nonce,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (bytes memory) {
        // Compute domain separator for EIP-712 (loan terms signature)
        bytes32 loanRouterDomainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("USDai Loan Router")),
                keccak256(bytes("1.0")),
                block.chainid,
                address(loanRouter)
            )
        );

        // Encode using the proper library function
        bytes32 structHash = this.encodeLenderSignatureExternal(loanTerms, nonce);

        // Create EIP-712 hash for loan terms
        bytes32 loanTermsDigest = keccak256(abi.encodePacked("\x19\x01", loanRouterDomainSeparator, structHash));

        // Sign loan terms
        (uint8 loanTermsV, bytes32 loanTermsR, bytes32 loanTermsS) = vm.sign(lenderPrivateKey, loanTermsDigest);

        bytes memory loanTermsSignature = abi.encodePacked(loanTermsR, loanTermsS, loanTermsV);

        // Compute domain separator for EIP-2612 permit (USDC)
        bytes32 permitDomainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("USD Coin")),
                keccak256(bytes("2")),
                block.chainid,
                USDC
            )
        );

        // Create permit struct hash
        bytes32 permitStructHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                IERC20Permit(USDC).nonces(owner), // Get current nonce from USDC contract
                deadline
            )
        );

        // Create EIP-712 hash for permit
        bytes32 permitDigest = keccak256(abi.encodePacked("\x19\x01", permitDomainSeparator, permitStructHash));

        // Sign permit
        (uint8 permitV, bytes32 permitR, bytes32 permitS) = vm.sign(lenderPrivateKey, permitDigest);

        // Encode with permit parameters
        return abi.encode(value, deadline, permitV, permitR, permitS, loanTermsSignature);
    }

    // External wrapper to call LenderSignatureLogic with calldata
    function encodeLenderSignatureExternal(
        ILoanRouter.LoanTerms calldata loanTerms,
        uint256 nonce
    ) external pure returns (bytes32) {
        return LoanTermsLogic.hashLoanTermsWithNonce(loanTerms, nonce);
    }

    function getLenderPrivateKey(
        address lender
    ) internal pure returns (uint256) {
        // This is a simplified approach for testing
        // In practice, you'd use vm.addr() to derive addresses from private keys
        if (lender == address(0x1)) return 1;
        if (lender == address(0x2)) return 2;
        if (lender == address(0x3)) return 3;
        return 0;
    }

    function warp(
        uint256 timeInSeconds
    ) internal {
        vm.warp(block.timestamp + timeInSeconds);
    }

    function warpToNextRepaymentWindow(
        uint64 repaymentDeadline
    ) internal {
        // Warp to just after the start of the repayment window
        // Repayment window starts at (repaymentDeadline - repaymentInterval)
        uint256 repaymentWindowStart = repaymentDeadline - REPAYMENT_INTERVAL + 1;
        if (block.timestamp < repaymentWindowStart) {
            vm.warp(repaymentWindowStart);
        }
    }

    function calculateExpectedInterest(
        uint256 principal,
        uint256 rate,
        uint256 duration
    ) internal pure returns (uint256) {
        return (principal * rate * duration) / FIXED_POINT_SCALE;
    }

    /**
     * @notice Calculate required repayment amount (unscaled)
     * @param loanTerms Loan terms
     * @return Required payment amount in currency token decimals
     */
    function calculateRequiredRepayment(
        ILoanRouter.LoanTerms memory loanTerms
    ) internal view returns (uint256) {
        (,, uint64 repaymentDeadline, uint256 balance) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Check if within repayment window
        bool isWithinRepaymentWindow = block.timestamp > repaymentDeadline - loanTerms.repaymentInterval;

        if (!isWithinRepaymentWindow) {
            return 0; // No payment required outside repayment window
        }

        // Get loan maturity
        (, uint64 maturity,,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Scale balance before passing to interest rate model (balance is now unscaled from loan())
        uint256 scaleFactor = 10 ** (18 - IERC20Metadata(loanTerms.currencyToken).decimals());

        // Call interest rate model to calculate required payment
        (uint256 principalPayment, uint256 interestPayment,,,) =
            interestRateModel.repayment(loanTerms, balance, repaymentDeadline, maturity, uint64(block.timestamp));

        // Convert from scaled (18 decimals) to token decimals (6 for USDC)
        // Round UP to ensure we don't underpay
        uint256 scaledTotal = principalPayment + interestPayment;
        uint256 unscaledTotalPayment =
            (scaledTotal % scaleFactor == 0) ? scaledTotal / scaleFactor : (scaledTotal / scaleFactor) + 1;

        return unscaledTotalPayment;
    }
}
