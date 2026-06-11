// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {BaseTest} from "../Base.t.sol";
import {ICollateralTimelock} from "src/interfaces/ICollateralTimelock.sol";

contract CollateralTimelockWithdrawTest is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Test: withdraw */
    /*------------------------------------------------------------------------*/

    function test__Withdraw_Success() public {
        address target = users.borrower;
        bytes32 context = keccak256("test-context-withdraw");
        uint64 expiration = uint64(block.timestamp + 7 days);
        uint256[] memory nftIds = new uint256[](2);
        nftIds[0] = 1;
        nftIds[1] = 2;

        vm.startPrank(users.borrower);

        testNFT.mint(users.borrower, nftIds[0]);
        testNFT.mint(users.borrower, nftIds[1]);
        testNFT.approve(address(collateralTimelock), nftIds[0]);
        testNFT.approve(address(collateralTimelock), nftIds[1]);

        collateralTimelock.deposit(target, context, address(testNFT), nftIds, expiration);

        vm.stopPrank();

        uint256 receiptTokenId = collateralTimelock.depositTokenId(target, context, address(testNFT), nftIds);

        vm.prank(target);
        vm.expectEmit(true, true, true, true);
        emit ICollateralTimelock.Withdrawn(users.borrower, target, context, address(testNFT), nftIds);
        collateralTimelock.withdraw(context, address(testNFT), nftIds);

        assertEq(testNFT.ownerOf(nftIds[0]), target, "Target should receive first NFT");
        assertEq(testNFT.ownerOf(nftIds[1]), target, "Target should receive second NFT");

        // Receipt token should be burned
        vm.expectRevert();
        collateralTimelock.ownerOf(receiptTokenId);

        // Deposit should be cleared
        (
            address depositor,,
            bytes32 storedContext,
            address storedToken,
            uint256[] memory storedTokenIds,
            uint64 storedExpiration
        ) = collateralTimelock.depositInfo(receiptTokenId);
        assertEq(depositor, address(0), "Depositor should be cleared");
        assertEq(storedContext, bytes32(0), "Context should be cleared");
        assertEq(storedToken, address(0), "Token should be cleared");
        assertEq(storedTokenIds.length, 0, "Token IDs should be cleared");
        assertEq(storedExpiration, 0, "Expiration should be cleared");
    }

    /*------------------------------------------------------------------------*/
    /* Test: withdraw failures */
    /*------------------------------------------------------------------------*/

    function test__Withdraw_RevertWhen_NotTarget() public {
        address target = users.borrower;
        bytes32 context = keccak256("test-context-not-target");
        uint64 expiration = uint64(block.timestamp + 7 days);
        uint256[] memory nftIds = new uint256[](1);
        nftIds[0] = 1;

        vm.startPrank(users.borrower);

        testNFT.mint(users.borrower, nftIds[0]);
        testNFT.approve(address(collateralTimelock), nftIds[0]);

        collateralTimelock.deposit(target, context, address(testNFT), nftIds, expiration);

        vm.stopPrank();

        // A non-target caller computes a different token ID, so no deposit is found
        vm.prank(users.lender1);
        vm.expectRevert(ICollateralTimelock.InvalidDeposit.selector);
        collateralTimelock.withdraw(context, address(testNFT), nftIds);
    }

    function test__Withdraw_RevertWhen_AfterExpiration() public {
        address target = users.borrower;
        bytes32 context = keccak256("test-context-expired");
        uint64 expiration = uint64(block.timestamp + 7 days);
        uint256[] memory nftIds = new uint256[](1);
        nftIds[0] = 1;

        vm.startPrank(users.borrower);

        testNFT.mint(users.borrower, nftIds[0]);
        testNFT.approve(address(collateralTimelock), nftIds[0]);

        collateralTimelock.deposit(target, context, address(testNFT), nftIds, expiration);

        vm.stopPrank();

        vm.warp(expiration + 1);

        vm.prank(target);
        vm.expectRevert(ICollateralTimelock.InvalidTimestamp.selector);
        collateralTimelock.withdraw(context, address(testNFT), nftIds);
    }

    function test__Withdraw_RevertWhen_Twice() public {
        address target = users.borrower;
        bytes32 context = keccak256("test-context-withdraw-twice");
        uint64 expiration = uint64(block.timestamp + 7 days);
        uint256[] memory nftIds = new uint256[](1);
        nftIds[0] = 1;

        vm.startPrank(users.borrower);

        testNFT.mint(users.borrower, nftIds[0]);
        testNFT.approve(address(collateralTimelock), nftIds[0]);

        collateralTimelock.deposit(target, context, address(testNFT), nftIds, expiration);

        vm.stopPrank();

        vm.startPrank(target);

        collateralTimelock.withdraw(context, address(testNFT), nftIds);

        vm.expectRevert(ICollateralTimelock.InvalidDeposit.selector);
        collateralTimelock.withdraw(context, address(testNFT), nftIds);

        vm.stopPrank();
    }

    function test__Withdraw_RevertWhen_DepositDoesNotExist() public {
        bytes32 context = keccak256("test-context-missing");
        uint256[] memory nftIds = new uint256[](1);
        nftIds[0] = 1;

        vm.prank(users.borrower);
        vm.expectRevert(ICollateralTimelock.InvalidDeposit.selector);
        collateralTimelock.withdraw(context, address(testNFT), nftIds);
    }

    function test__Withdraw_RevertWhen_ZeroContext() public {
        uint256[] memory nftIds = new uint256[](1);
        nftIds[0] = 1;

        vm.prank(users.borrower);
        vm.expectRevert(ICollateralTimelock.InvalidBytes32.selector);
        collateralTimelock.withdraw(bytes32(0), address(testNFT), nftIds);
    }

    function test__Withdraw_RevertWhen_ZeroToken() public {
        bytes32 context = keccak256("test-context-zero-token");
        uint256[] memory nftIds = new uint256[](1);
        nftIds[0] = 1;

        vm.prank(users.borrower);
        vm.expectRevert(ICollateralTimelock.InvalidAddress.selector);
        collateralTimelock.withdraw(context, address(0), nftIds);
    }

    function test__Withdraw_RevertWhen_EmptyTokenIds() public {
        bytes32 context = keccak256("test-context-empty-ids");
        uint256[] memory emptyIds = new uint256[](0);

        vm.prank(users.borrower);
        vm.expectRevert(ICollateralTimelock.InvalidDeposit.selector);
        collateralTimelock.withdraw(context, address(testNFT), emptyIds);
    }
}
