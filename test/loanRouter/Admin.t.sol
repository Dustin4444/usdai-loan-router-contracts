// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {BaseTest} from "../Base.t.sol";
import {ILoanRouter} from "src/interfaces/ILoanRouter.sol";
import {ICollateralLiquidationReceiver} from "src/interfaces/external/ICollateralLiquidationReceiver.sol";

import {IERC165} from "lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IERC5267} from "lib/openzeppelin-contracts/contracts/interfaces/IERC5267.sol";
import {IERC721Enumerable} from "lib/openzeppelin-contracts/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {IAccessControl} from "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";

contract LoanRouterAdminTest is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Test: setFeeRecipient */
    /*------------------------------------------------------------------------*/

    function test__SetFeeRecipient_Success() public {
        address newFeeRecipient = makeAddr("newFeeRecipient");

        vm.startPrank(users.deployer);
        vm.expectEmit(true, true, true, true);
        emit ILoanRouter.FeeRecipientSet(newFeeRecipient);
        loanRouter.setFeeRecipient(newFeeRecipient);
        vm.stopPrank();
    }

    function test__SetFeeRecipient_RevertWhen_NotAdmin() public {
        address newFeeRecipient = makeAddr("newFeeRecipient");

        vm.startPrank(users.borrower);
        vm.expectRevert();
        loanRouter.setFeeRecipient(newFeeRecipient);
        vm.stopPrank();
    }

    function test__SetFeeRecipient_RevertWhen_ZeroAddress() public {
        vm.startPrank(users.deployer);
        vm.expectRevert(ILoanRouter.InvalidAddress.selector);
        loanRouter.setFeeRecipient(address(0));
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: increaseNonce */
    /*------------------------------------------------------------------------*/

    function test__IncreaseNonce_Success() public {
        uint256 principal = 100_000 * 1e6;
        uint256 originationFee = 1_000 * 1e6;
        uint256 exitFee = 500 * 1e6;

        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 1, originationFee, exitFee);

        bytes32 loanTermsHash = loanRouter.loanTermsHash(loanTerms);

        vm.startPrank(users.lender1);
        vm.expectEmit(true, true, true, true);
        emit ILoanRouter.NonceIncreased(loanTermsHash, users.lender1, 1);
        loanRouter.increaseNonce(loanTerms);
        vm.stopPrank();
    }

    function test__IncreaseNonce_Multiple() public {
        uint256 principal = 100_000 * 1e6;
        uint256 originationFee = 1_000 * 1e6;
        uint256 exitFee = 500 * 1e6;

        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 1, originationFee, exitFee);

        bytes32 loanTermsHash = loanRouter.loanTermsHash(loanTerms);

        // Increase nonce multiple times
        vm.startPrank(users.lender1);

        loanRouter.increaseNonce(loanTerms);
        loanRouter.increaseNonce(loanTerms);

        vm.expectEmit(true, true, true, true);
        emit ILoanRouter.NonceIncreased(loanTermsHash, users.lender1, 3);
        loanRouter.increaseNonce(loanTerms);

        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: Loan getters */
    /*------------------------------------------------------------------------*/

    function test__LoanTermsHash_Consistency() public view {
        uint256 principal = 100_000 * 1e6;
        uint256 originationFee = 1_000 * 1e6;
        uint256 exitFee = 500 * 1e6;

        ILoanRouter.LoanTerms memory loanTerms1 = createLoanTerms(users.borrower, principal, 1, originationFee, exitFee);
        ILoanRouter.LoanTerms memory loanTerms2 = createLoanTerms(users.borrower, principal, 1, originationFee, exitFee);

        // Same terms should produce same hash
        assertEq(loanRouter.loanTermsHash(loanTerms1), loanRouter.loanTermsHash(loanTerms2));

        // Different terms should produce different hash
        loanTerms2.trancheSpecs[0].amount = principal - 1;
        assertTrue(loanRouter.loanTermsHash(loanTerms1) != loanRouter.loanTermsHash(loanTerms2));
    }

    function test__LoanTokenIds() public view {
        uint256 principal = 200_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = createLoanTerms(users.borrower, principal, 2, 0, 0);

        uint256[] memory tokenIds = loanRouter.loanTokenIds(loanTerms);

        assertEq(tokenIds.length, 2, "Should have 2 token IDs");
    }

    /*------------------------------------------------------------------------*/
    /* Test: Access control */
    /*------------------------------------------------------------------------*/

    function test__AccessControl_DefaultAdmin() public view {
        bytes32 defaultAdminRole = 0x00; // DEFAULT_ADMIN_ROLE

        assertTrue(loanRouter.hasRole(defaultAdminRole, users.deployer), "Deployer should have admin role");
        assertFalse(loanRouter.hasRole(defaultAdminRole, users.borrower), "Borrower should not have admin role");
    }

    function test__AccessControl_GrantRole() public {
        bytes32 defaultAdminRole = 0x00;

        vm.startPrank(users.deployer);
        loanRouter.grantRole(defaultAdminRole, users.admin);
        vm.stopPrank();

        assertTrue(loanRouter.hasRole(defaultAdminRole, users.admin), "Admin should have admin role");
    }

    function test__AccessControl_RevokeRole() public {
        bytes32 defaultAdminRole = 0x00;

        // Grant role first
        vm.startPrank(users.deployer);
        loanRouter.grantRole(defaultAdminRole, users.admin);
        assertTrue(loanRouter.hasRole(defaultAdminRole, users.admin));

        // Revoke role
        loanRouter.revokeRole(defaultAdminRole, users.admin);
        vm.stopPrank();

        assertFalse(loanRouter.hasRole(defaultAdminRole, users.admin), "Admin role should be revoked");
    }

    /*------------------------------------------------------------------------*/
    /* Test: ERC721 functionality */
    /*------------------------------------------------------------------------*/

    function test__ERC721_Transfer_LenderPosition() public {
        uint256 principal = 100_000 * 1e6;

        // Setup and borrow
        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 1);

        // Get token ID
        uint256[] memory tokenIds = loanRouter.loanTokenIds(loanTerms);
        uint256 tokenId = tokenIds[0];

        // Transfer position to another address
        address newOwner = makeAddr("newOwner");

        vm.startPrank(users.lender1);
        loanRouter.transferFrom(users.lender1, newOwner, tokenId);
        vm.stopPrank();

        // Verify transfer
        assertEq(loanRouter.ownerOf(tokenId), newOwner, "Position should be transferred");
    }

    function test__ERC721_Approval_LenderPosition() public {
        uint256 principal = 100_000 * 1e6;

        // Setup and borrow
        (ILoanRouter.LoanTerms memory loanTerms,) = setupLoan(principal, 1);

        // Get token ID
        uint256[] memory tokenIds = loanRouter.loanTokenIds(loanTerms);
        uint256 tokenId = tokenIds[0];

        address approved = makeAddr("approved");

        // Approve
        vm.startPrank(users.lender1);
        loanRouter.approve(approved, tokenId);
        vm.stopPrank();

        // Verify approval
        assertEq(loanRouter.getApproved(tokenId), approved, "Should be approved");
    }

    /*------------------------------------------------------------------------*/
    /* Helper function */
    /*------------------------------------------------------------------------*/

    function setupLoan(
        uint256 principal,
        uint256 numTranches
    ) internal returns (ILoanRouter.LoanTerms memory loanTerms, bytes32 loanTermsHash) {
        uint256 originationFee = principal / 100;
        uint256 exitFee = principal / 200;

        loanTerms = createLoanTerms(users.borrower, principal, numTranches, originationFee, exitFee);
        loanTermsHash = loanRouter.loanTermsHash(loanTerms);

        address[] memory lenders = new address[](3);
        lenders[0] = users.lender1;
        lenders[1] = users.lender2;
        lenders[2] = users.lender3;

        for (uint256 i = 0; i < numTranches; i++) {
            vm.startPrank(lenders[i]);
            // Apply 1.6bps slippage and convert to USDai decimals
            uint256 depositAmount = (loanTerms.trancheSpecs[i].amount * 10016 * 1e12) / 10000;
            depositTimelock.deposit(address(loanRouter), loanTermsHash, USDAI, depositAmount, loanTerms.expiration);
            vm.stopPrank();
        }

        vm.startPrank(users.borrower);

        ILoanRouter.LenderDepositInfo[] memory lenderDepositInfos = createDepositTimelockInfos(numTranches);

        loanRouter.borrow(loanTerms, lenderDepositInfos);
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: SupportsInterface */
    /*------------------------------------------------------------------------*/

    function test__SupportsInterface() public view {
        assertTrue(loanRouter.supportsInterface(type(IERC165).interfaceId));
        assertTrue(loanRouter.supportsInterface(type(IERC721).interfaceId));
        assertTrue(loanRouter.supportsInterface(type(IERC5267).interfaceId));
        assertTrue(loanRouter.supportsInterface(type(ILoanRouter).interfaceId));
        assertTrue(loanRouter.supportsInterface(type(IERC721Enumerable).interfaceId));
        assertTrue(loanRouter.supportsInterface(type(ICollateralLiquidationReceiver).interfaceId));
        assertTrue(loanRouter.supportsInterface(type(IAccessControl).interfaceId));
    }
}
