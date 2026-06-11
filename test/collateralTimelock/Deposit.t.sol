// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {BaseTest} from "../Base.t.sol";
import {ICollateralTimelock} from "src/interfaces/ICollateralTimelock.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract CollateralTimelockDepositTest is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Test: deposit */
    /*------------------------------------------------------------------------*/

    function test__Deposit_Success() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint64 expiration = uint64(block.timestamp + 7 days);
        uint256[] memory nftIds = new uint256[](2);
        nftIds[0] = 1;
        nftIds[1] = 2;

        vm.startPrank(users.borrower);

        testNFT.mint(users.borrower, nftIds[0]);
        testNFT.mint(users.borrower, nftIds[1]);
        testNFT.approve(address(collateralTimelock), nftIds[0]);
        testNFT.approve(address(collateralTimelock), nftIds[1]);

        vm.expectEmit(true, true, true, true);
        emit ICollateralTimelock.Deposited(users.borrower, target, context, address(testNFT), nftIds, expiration);
        collateralTimelock.deposit(target, context, address(testNFT), nftIds, expiration);

        vm.stopPrank();

        uint256 receiptTokenId = collateralTimelock.depositTokenId(target, context, address(testNFT), nftIds);

        // Verify deposit was recorded
        (
            address depositor,
            address storedTarget,
            bytes32 storedContext,
            address storedToken,
            uint256[] memory storedTokenIds,
            uint64 storedExpiration
        ) = collateralTimelock.depositInfo(receiptTokenId);

        assertEq(depositor, users.borrower, "Depositor should match");
        assertEq(storedTarget, target, "Target should match");
        assertEq(storedContext, context, "Context should match");
        assertEq(storedToken, address(testNFT), "Token should match");
        assertEq(storedTokenIds.length, 2, "Token IDs length should match");
        assertEq(storedTokenIds[0], nftIds[0], "First token ID should match");
        assertEq(storedTokenIds[1], nftIds[1], "Second token ID should match");
        assertEq(storedExpiration, expiration, "Expiration should match");

        // Verify NFTs were escrowed
        assertEq(testNFT.balanceOf(address(collateralTimelock)), 2, "CollateralTimelock should hold 2 NFTs");

        // Verify receipt token was minted to depositor
        assertEq(collateralTimelock.ownerOf(receiptTokenId), users.borrower, "Receipt should be owned by depositor");
    }

    function test__Deposit_ReceiptIsNonTransferable() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context-nft-receipt");
        uint64 expiration = uint64(block.timestamp + 7 days);
        uint256[] memory nftIds = new uint256[](1);
        nftIds[0] = 1;

        vm.startPrank(users.borrower);

        testNFT.mint(users.borrower, nftIds[0]);
        testNFT.approve(address(collateralTimelock), nftIds[0]);

        collateralTimelock.deposit(target, context, address(testNFT), nftIds, expiration);

        uint256 receiptTokenId = collateralTimelock.depositTokenId(target, context, address(testNFT), nftIds);

        vm.expectRevert();
        collateralTimelock.approve(users.lender1, receiptTokenId);

        vm.expectRevert();
        collateralTimelock.transferFrom(users.borrower, users.lender1, receiptTokenId);

        vm.expectRevert();
        collateralTimelock.safeTransferFrom(users.borrower, users.lender1, receiptTokenId, "");

        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: deposit failures */
    /*------------------------------------------------------------------------*/

    function test__Deposit_RevertWhen_AlreadyExists() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context-second");
        uint64 expiration = uint64(block.timestamp + 7 days);
        uint256[] memory nftIds = new uint256[](1);
        nftIds[0] = 1;

        vm.startPrank(users.borrower);

        testNFT.mint(users.borrower, nftIds[0]);
        testNFT.approve(address(collateralTimelock), nftIds[0]);

        collateralTimelock.deposit(target, context, address(testNFT), nftIds, expiration);

        // Same parameters compute the same receipt token ID
        vm.expectRevert(ICollateralTimelock.InvalidDeposit.selector);
        collateralTimelock.deposit(target, context, address(testNFT), nftIds, expiration);

        vm.stopPrank();
    }

    function test__Deposit_RevertWhen_EmptyTokenIds() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context-empty");
        uint64 expiration = uint64(block.timestamp + 7 days);
        uint256[] memory emptyIds = new uint256[](0);

        vm.startPrank(users.borrower);
        vm.expectRevert(ICollateralTimelock.InvalidAmount.selector);
        collateralTimelock.deposit(target, context, address(testNFT), emptyIds, expiration);
        vm.stopPrank();
    }

    function test__Deposit_RevertWhen_ZeroTarget() public {
        bytes32 context = keccak256("test-context");
        uint64 expiration = uint64(block.timestamp + 7 days);
        uint256[] memory nftIds = new uint256[](1);
        nftIds[0] = 1;

        vm.startPrank(users.borrower);
        vm.expectRevert(ICollateralTimelock.InvalidAddress.selector);
        collateralTimelock.deposit(address(0), context, address(testNFT), nftIds, expiration);
        vm.stopPrank();
    }

    function test__Deposit_RevertWhen_ZeroToken() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint64 expiration = uint64(block.timestamp + 7 days);
        uint256[] memory nftIds = new uint256[](1);
        nftIds[0] = 1;

        vm.startPrank(users.borrower);
        vm.expectRevert(ICollateralTimelock.InvalidAddress.selector);
        collateralTimelock.deposit(target, context, address(0), nftIds, expiration);
        vm.stopPrank();
    }

    function test__Deposit_RevertWhen_ZeroContext() public {
        address target = address(loanRouter);
        uint64 expiration = uint64(block.timestamp + 7 days);
        uint256[] memory nftIds = new uint256[](1);
        nftIds[0] = 1;

        vm.startPrank(users.borrower);
        vm.expectRevert(ICollateralTimelock.InvalidBytes32.selector);
        collateralTimelock.deposit(target, bytes32(0), address(testNFT), nftIds, expiration);
        vm.stopPrank();
    }

    function test__Deposit_RevertWhen_ExpirationInPast() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256[] memory nftIds = new uint256[](1);
        nftIds[0] = 1;

        vm.startPrank(users.borrower);

        testNFT.mint(users.borrower, nftIds[0]);
        testNFT.approve(address(collateralTimelock), nftIds[0]);

        vm.expectRevert(ICollateralTimelock.InvalidTimestamp.selector);
        collateralTimelock.deposit(target, context, address(testNFT), nftIds, uint64(block.timestamp));

        vm.stopPrank();
    }

    function test__Deposit_RevertWhen_MissingRole() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint64 expiration = uint64(block.timestamp + 7 days);
        uint256[] memory nftIds = new uint256[](1);
        nftIds[0] = 1;

        // users.lender2 has not been granted DEPOSITOR_ROLE
        vm.startPrank(users.lender2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, users.lender2, keccak256("DEPOSITOR_ROLE")
            )
        );
        collateralTimelock.deposit(target, context, address(testNFT), nftIds, expiration);
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: depositInfo getter */
    /*------------------------------------------------------------------------*/

    function test__DepositInfo_NonExistent() public view {
        address target = address(loanRouter);
        bytes32 context = keccak256("nonexistent");
        uint256[] memory nftIds = new uint256[](1);
        nftIds[0] = 1;

        (address depositor,,, address token, uint256[] memory tokenIds, uint64 expiration) =
            collateralTimelock.depositInfo(collateralTimelock.depositTokenId(target, context, address(testNFT), nftIds));

        assertEq(depositor, address(0), "Depositor should be zero for nonexistent deposit");
        assertEq(token, address(0), "Token should be zero for nonexistent deposit");
        assertEq(tokenIds.length, 0, "Token IDs should be empty for nonexistent deposit");
        assertEq(expiration, 0, "Expiration should be zero for nonexistent deposit");
    }
}
