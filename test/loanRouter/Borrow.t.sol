// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {BaseTest} from "../Base.t.sol";
import {ILoanRouter} from "src/interfaces/ILoanRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract LoanRouterBorrowTest is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Test: Borrow with DepositTimelock funding */
    /*------------------------------------------------------------------------*/

    function test__Borrow_WithDepositTimelock_SingleTranche() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC
        uint256 originationFee = 1_000 * 1e6; // 1k USDC
        uint256 exitFee = 500 * 1e6; // 500 USDC

        // Create loan terms with single tranche
        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 1, originationFee, exitFee);

        // Lender1 deposits to DepositTimelock (convert USDC amount to USDai decimals + 1.6bps for slippage)
        vm.startPrank(users.lender1);
        bytes32 loanTermsHash = loanRouter.loanTermsHash(loanTerms);
        uint256 depositAmount = (principal * 10016 * 1e12) / 10000; // Convert 6 decimals to 18 decimals + 1.6bps
        depositTimelock.deposit(address(loanRouter), loanTermsHash, USDAI, depositAmount, loanTerms.expiration);
        vm.stopPrank();

        // Record balances before
        uint256 borrowerUsdcBefore = IERC20(USDC).balanceOf(users.borrower);
        uint256 feeRecipientUsdcBefore = IERC20(USDC).balanceOf(users.feeRecipient);

        // Borrower borrows funds
        vm.startPrank(users.borrower);

        ILoanRouter.LenderDepositInfo[] memory lenderDepositInfos = createDepositTimelockInfos(1);

        loanRouter.borrow(loanTerms, lenderDepositInfos);

        vm.stopPrank();

        // Verify loan state
        (ILoanRouter.LoanStatus status, uint64 maturity, uint64 repaymentDeadline, uint256 balance) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        assertEq(uint8(status), uint8(ILoanRouter.LoanStatus.Active), "Loan should be active");
        assertEq(maturity, uint64(block.timestamp) + LOAN_DURATION, "Maturity should be set");
        assertEq(repaymentDeadline, uint64(block.timestamp) + REPAYMENT_INTERVAL, "Repayment deadline should be set");
        assertEq(balance, principal * 1e12, "Balance should equal principal");

        // Verify borrower received principal minus fee
        assertEq(
            IERC20(USDC).balanceOf(users.borrower) - borrowerUsdcBefore,
            principal - originationFee,
            "Borrower should receive principal minus origination fee"
        );

        // Verify fee recipient received origination fee
        assertEq(
            IERC20(USDC).balanceOf(users.feeRecipient) - feeRecipientUsdcBefore,
            originationFee,
            "Fee recipient should receive origination fee"
        );

        // Verify lender received tokenized position
        uint256[] memory tokenIds = loanRouter.loanTokenIds(loanTerms);
        assertEq(loanRouter.ownerOf(tokenIds[0]), users.lender1, "Lender1 should own the NFT position");

        // Verify collateral is locked in LoanRouter
        assertEq(
            IERC721(address(bundleCollateralWrapper)).ownerOf(wrappedTokenId),
            address(loanRouter),
            "Collateral should be locked in LoanRouter"
        );
    }

    function test__Borrow_WithDepositTimelock_MultipleTranches() public {
        uint256 principal = 300_000 * 1e6; // 300k USDC
        uint256 originationFee = 3_000 * 1e6; // 3k USDC
        uint256 exitFee = 1_500 * 1e6; // 1.5k USDC

        // Create loan terms with 3 tranches
        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 3, originationFee, exitFee);

        bytes32 loanTermsHash = loanRouter.loanTermsHash(loanTerms);

        // All 3 lenders deposit to DepositTimelock (convert USDC amounts to USDai decimals + 1.6bps for slippage)
        vm.startPrank(users.lender1);
        uint256 depositAmount1 = (loanTerms.trancheSpecs[0].amount * 10016 * 1e12) / 10000;
        depositTimelock.deposit(address(loanRouter), loanTermsHash, USDAI, depositAmount1, loanTerms.expiration);
        vm.stopPrank();

        vm.startPrank(users.lender2);
        uint256 depositAmount2 = (loanTerms.trancheSpecs[1].amount * 10016 * 1e12) / 10000;
        depositTimelock.deposit(address(loanRouter), loanTermsHash, USDAI, depositAmount2, loanTerms.expiration);
        vm.stopPrank();

        vm.startPrank(users.lender3);
        uint256 depositAmount3 = (loanTerms.trancheSpecs[2].amount * 10016 * 1e12) / 10000;
        depositTimelock.deposit(address(loanRouter), loanTermsHash, USDAI, depositAmount3, loanTerms.expiration);
        vm.stopPrank();

        // Borrower borrows funds
        vm.startPrank(users.borrower);

        ILoanRouter.LenderDepositInfo[] memory lenderDepositInfos = createDepositTimelockInfos(3);

        loanRouter.borrow(loanTerms, lenderDepositInfos);

        vm.stopPrank();

        // Verify all lenders received tokenized positions
        uint256[] memory tokenIds = loanRouter.loanTokenIds(loanTerms);
        assertEq(loanRouter.ownerOf(tokenIds[0]), users.lender1, "Lender1 should own NFT 0");
        assertEq(loanRouter.ownerOf(tokenIds[1]), users.lender2, "Lender2 should own NFT 1");
        assertEq(loanRouter.ownerOf(tokenIds[2]), users.lender3, "Lender3 should own NFT 2");
    }

    function test__Borrow_WithDepositTimelock_SingleTranche_Uniswap() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC
        uint256 originationFee = 1_000 * 1e6; // 1k USDC
        uint256 exitFee = 500 * 1e6; // 500 USDC

        // Create loan terms with single tranche
        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 1, originationFee, exitFee);

        // Lender1 deposits to DepositTimelock (convert USDC amount to USDai decimals + 1.6bps for slippage)
        vm.startPrank(users.lender1);
        bytes32 loanTermsHash = loanRouter.loanTermsHash(loanTerms);
        uint256 depositAmount = (principal * 10016) / 10000;
        depositTimelock.deposit(address(loanRouter), loanTermsHash, USDT, depositAmount, loanTerms.expiration);
        vm.stopPrank();

        // Record balances before
        uint256 borrowerUsdcBefore = IERC20(USDC).balanceOf(users.borrower);
        uint256 feeRecipientUsdcBefore = IERC20(USDC).balanceOf(users.feeRecipient);

        // Borrower borrows funds
        vm.startPrank(users.borrower);

        ILoanRouter.LenderDepositInfo[] memory lenderDepositInfos = createDepositTimelockInfosUniswap(1);
        loanRouter.borrow(loanTerms, lenderDepositInfos);

        vm.stopPrank();

        // Verify loan state
        (ILoanRouter.LoanStatus status, uint64 maturity, uint64 repaymentDeadline, uint256 balance) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        assertEq(uint8(status), uint8(ILoanRouter.LoanStatus.Active), "Loan should be active");
        assertEq(maturity, uint64(block.timestamp) + LOAN_DURATION, "Maturity should be set");
        assertEq(repaymentDeadline, uint64(block.timestamp) + REPAYMENT_INTERVAL, "Repayment deadline should be set");
        assertEq(balance, principal * 1e12, "Balance should equal principal");

        // Verify borrower received principal minus fee
        assertEq(
            IERC20(USDC).balanceOf(users.borrower) - borrowerUsdcBefore,
            principal - originationFee,
            "Borrower should receive principal minus origination fee"
        );

        // Verify fee recipient received origination fee
        assertEq(
            IERC20(USDC).balanceOf(users.feeRecipient) - feeRecipientUsdcBefore,
            originationFee,
            "Fee recipient should receive origination fee"
        );

        // Verify lender received tokenized position
        uint256[] memory tokenIds = loanRouter.loanTokenIds(loanTerms);
        assertEq(loanRouter.ownerOf(tokenIds[0]), users.lender1, "Lender1 should own the NFT position");

        // Verify collateral is locked in LoanRouter
        assertEq(
            IERC721(address(bundleCollateralWrapper)).ownerOf(wrappedTokenId),
            address(loanRouter),
            "Collateral should be locked in LoanRouter"
        );
    }

    /*------------------------------------------------------------------------*/
    /* Test: Borrow with signature-based funding */
    /*------------------------------------------------------------------------*/

    function test__Borrow_WithSignature_SingleTranche() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC
        uint256 originationFee = 1_000 * 1e6; // 1k USDC
        uint256 exitFee = 500 * 1e6; // 500 USDC

        // Create loan terms
        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 1, originationFee, exitFee);

        // Get lender private key for signing
        (address lender1Addr, uint256 lender1PK) = makeAddrAndKey("lender1Signer");

        // Update loan terms to use the signer address
        loanTerms.trancheSpecs[0].lender = lender1Addr;

        // Fund the signer with USDC
        vm.startPrank(users.lender1);
        IERC20(USDC).transfer(lender1Addr, principal);
        vm.stopPrank();

        // Approve LoanRouter to spend USDC
        vm.startPrank(lender1Addr);
        IERC20(USDC).approve(address(loanRouter), type(uint256).max);
        vm.stopPrank();

        // Sign loan terms
        bytes memory signature = signLoanTerms(loanTerms, lender1PK, 0);

        // Record balances
        uint256 borrowerUsdcBefore = IERC20(USDC).balanceOf(users.borrower);
        uint256 lender1UsdcBefore = IERC20(USDC).balanceOf(lender1Addr);

        // Borrower borrows funds
        vm.startPrank(users.borrower);

        ILoanRouter.LenderDepositInfo[] memory lenderDepositInfos = new ILoanRouter.LenderDepositInfo[](1);
        lenderDepositInfos[0] = createERC20ApprovalInfo(signature);

        loanRouter.borrow(loanTerms, lenderDepositInfos);

        vm.stopPrank();

        // Verify lender's USDC was transferred
        assertEq(
            lender1UsdcBefore - IERC20(USDC).balanceOf(lender1Addr),
            principal,
            "Lender should have transferred principal"
        );

        // Verify borrower received funds
        assertEq(
            IERC20(USDC).balanceOf(users.borrower) - borrowerUsdcBefore,
            principal - originationFee,
            "Borrower should receive principal minus fee"
        );

        // Verify lender received NFT position
        uint256[] memory tokenIds = loanRouter.loanTokenIds(loanTerms);
        assertEq(loanRouter.ownerOf(tokenIds[0]), lender1Addr, "Lender should own the NFT position");
    }

    function test__Borrow_WithPermit_SingleTranche() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC
        uint256 originationFee = 1_000 * 1e6; // 1k USDC
        uint256 exitFee = 500 * 1e6; // 500 USDC

        // Create loan terms
        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 1, originationFee, exitFee);

        // Get lender private key for signing
        (address lender1Addr, uint256 lender1PK) = makeAddrAndKey("lender1PermitSigner");

        // Update loan terms to use the signer address
        loanTerms.trancheSpecs[0].lender = lender1Addr;

        // Fund the signer with USDC
        vm.startPrank(users.lender1);
        IERC20(USDC).transfer(lender1Addr, principal);
        vm.stopPrank();

        // DO NOT approve LoanRouter - we'll use permit instead

        // Sign loan terms with permit
        uint256 permitDeadline = block.timestamp + 1 hours;
        bytes memory signature = signLoanTermsWithPermit(
            loanTerms,
            lender1PK,
            0, // nonce
            lender1Addr, // owner
            address(loanRouter), // spender
            principal, // value
            permitDeadline
        );

        // Record balances
        uint256 borrowerUsdcBefore = IERC20(USDC).balanceOf(users.borrower);
        uint256 lender1UsdcBefore = IERC20(USDC).balanceOf(lender1Addr);

        // Borrower borrows funds
        vm.startPrank(users.borrower);

        ILoanRouter.LenderDepositInfo[] memory lenderDepositInfos = new ILoanRouter.LenderDepositInfo[](1);
        lenderDepositInfos[0] = createERC20PermitInfo(signature);

        loanRouter.borrow(loanTerms, lenderDepositInfos);

        vm.stopPrank();

        // Verify lender's USDC was transferred (without pre-approval!)
        assertEq(
            lender1UsdcBefore - IERC20(USDC).balanceOf(lender1Addr),
            principal,
            "Lender should have transferred principal"
        );

        // Verify borrower received funds
        assertEq(
            IERC20(USDC).balanceOf(users.borrower) - borrowerUsdcBefore,
            principal - originationFee,
            "Borrower should receive principal minus fee"
        );

        // Verify lender received NFT position
        uint256[] memory tokenIds = loanRouter.loanTokenIds(loanTerms);
        assertEq(loanRouter.ownerOf(tokenIds[0]), lender1Addr, "Lender should own the NFT position");

        // Verify loan state
        (ILoanRouter.LoanStatus status,,,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(uint8(status), uint8(ILoanRouter.LoanStatus.Active), "Loan should be active");
    }

    /*------------------------------------------------------------------------*/
    /* Test: Borrow with mixed funding (DepositTimelock + Signature) */
    /*------------------------------------------------------------------------*/

    function test__Borrow_MixedFunding() public {
        uint256 principal = 200_000 * 1e6; // 200k USDC
        uint256 originationFee = 2_000 * 1e6; // 2k USDC
        uint256 exitFee = 1_000 * 1e6; // 1k USDC

        // Create lender2 signer address first
        (address lender2Addr, uint256 lender2PK) = makeAddrAndKey("lender2Signer");

        // Create loan terms with 2 tranches
        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 2, originationFee, exitFee);

        // Update tranche 1 to use lender2 signer BEFORE computing hash
        loanTerms.trancheSpecs[1].lender = lender2Addr;

        bytes32 loanTermsHash = loanRouter.loanTermsHash(loanTerms);

        // Lender1 uses DepositTimelock (convert USDC amount to USDai decimals + 1.6bps for slippage)
        vm.startPrank(users.lender1);
        uint256 depositAmount1 = (loanTerms.trancheSpecs[0].amount * 10016 * 1e12) / 10000;
        depositTimelock.deposit(address(loanRouter), loanTermsHash, USDAI, depositAmount1, loanTerms.expiration);
        vm.stopPrank();

        // Lender2 uses signature

        // Fund lender2
        vm.startPrank(users.lender2);
        IERC20(USDC).transfer(lender2Addr, loanTerms.trancheSpecs[1].amount);
        vm.stopPrank();

        vm.startPrank(lender2Addr);
        IERC20(USDC).approve(address(loanRouter), type(uint256).max);
        vm.stopPrank();

        // Sign for lender2
        bytes memory signature2 = signLoanTerms(loanTerms, lender2PK, 0);

        // Borrower borrows
        vm.startPrank(users.borrower);

        ILoanRouter.LenderDepositInfo[] memory lenderDepositInfos = new ILoanRouter.LenderDepositInfo[](2);
        lenderDepositInfos[0] =
            ILoanRouter.LenderDepositInfo({depositType: ILoanRouter.DepositType.DepositTimelock, data: ""});
        lenderDepositInfos[1] = createERC20ApprovalInfo(signature2);

        loanRouter.borrow(loanTerms, lenderDepositInfos);

        vm.stopPrank();

        // Verify both lenders received positions
        uint256[] memory tokenIds = loanRouter.loanTokenIds(loanTerms);
        assertEq(loanRouter.ownerOf(tokenIds[0]), users.lender1, "Lender1 should own position 0");
        assertEq(loanRouter.ownerOf(tokenIds[1]), lender2Addr, "Lender2 should own position 1");
    }

    /*------------------------------------------------------------------------*/
    /* Test: Borrow failures */
    /*------------------------------------------------------------------------*/

    function test__Borrow_RevertWhen_AfterExpiration() public {
        uint256 principal = 100_000 * 1e6;
        uint256 originationFee = 1_000 * 1e6;
        uint256 exitFee = 500 * 1e6;

        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 1, originationFee, exitFee);

        bytes32 loanTermsHash = loanRouter.loanTermsHash(loanTerms);

        // Lender deposits first (convert USDC amount to USDai decimals + 1.6bps for slippage)
        vm.startPrank(users.lender1);
        uint256 depositAmount = (principal * 10016 * 1e12) / 10000;
        depositTimelock.deposit(address(loanRouter), loanTermsHash, USDAI, depositAmount, loanTerms.expiration);
        vm.stopPrank();

        // Warp past expiration
        vm.warp(loanTerms.expiration + 1);

        // This should fail due to DepositTimelock expiration check
        vm.startPrank(users.borrower);

        ILoanRouter.LenderDepositInfo[] memory lenderDepositInfos = createDepositTimelockInfos(1);

        // Expect revert from DepositTimelock
        vm.expectRevert();
        loanRouter.borrow(loanTerms, lenderDepositInfos);

        vm.stopPrank();
    }

    function test__Borrow_RevertWhen_NotBorrower() public {
        uint256 principal = 100_000 * 1e6;
        uint256 originationFee = 1_000 * 1e6;
        uint256 exitFee = 500 * 1e6;

        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 1, originationFee, exitFee);

        bytes32 loanTermsHash = loanRouter.loanTermsHash(loanTerms);

        // Convert USDC amount to USDai decimals + 1.6bps for slippage
        uint256 depositAmount = (principal * 10016 * 1e12) / 10000;

        vm.startPrank(users.lender1);
        depositTimelock.deposit(address(loanRouter), loanTermsHash, USDAI, depositAmount, loanTerms.expiration);
        vm.stopPrank();

        // Try to borrow as different user
        vm.startPrank(users.lender2);

        ILoanRouter.LenderDepositInfo[] memory lenderDepositInfos = createDepositTimelockInfos(1);

        vm.expectRevert(ILoanRouter.InvalidCaller.selector);
        loanRouter.borrow(loanTerms, lenderDepositInfos);

        vm.stopPrank();
    }

    function test__Borrow_RevertWhen_LoanAlreadyExists() public {
        uint256 principal = 100_000 * 1e6;
        uint256 originationFee = 1_000 * 1e6;
        uint256 exitFee = 500 * 1e6;

        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 1, originationFee, exitFee);

        bytes32 loanTermsHash = loanRouter.loanTermsHash(loanTerms);

        // Convert USDC amount to USDai decimals + 1.6bps for slippage
        uint256 depositAmount = (principal * 10016 * 1e12) / 10000;

        vm.startPrank(users.lender1);
        depositTimelock.deposit(address(loanRouter), loanTermsHash, USDAI, depositAmount, loanTerms.expiration);
        vm.stopPrank();

        // First borrow
        vm.startPrank(users.borrower);

        ILoanRouter.LenderDepositInfo[] memory lenderDepositInfos = createDepositTimelockInfos(1);

        loanRouter.borrow(loanTerms, lenderDepositInfos);

        // Try to borrow again with same terms
        vm.expectRevert(ILoanRouter.InvalidLoanState.selector);
        loanRouter.borrow(loanTerms, lenderDepositInfos);

        vm.stopPrank();
    }
}
