// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {BaseTest} from "../Base.t.sol";
import {ICollateralTimelock} from "src/interfaces/ICollateralTimelock.sol";

contract CollateralTimelockCancelTest is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Test: cancel */
    /*------------------------------------------------------------------------*/

    function test__Cancel_Success() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context-cancel");
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

        assertEq(testNFT.balanceOf(address(collateralTimelock)), 2, "CollateralTimelock should hold 2 NFTs");

        vm.warp(expiration + 1);

        vm.prank(users.borrower);
        vm.expectEmit(true, true, true, true);
        emit ICollateralTimelock.Canceled(users.borrower, target, context, address(testNFT), nftIds);
        collateralTimelock.cancel(target, context, address(testNFT), nftIds);

        assertEq(testNFT.balanceOf(users.borrower), 2, "Depositor should have received 2 NFTs");
        assertEq(testNFT.balanceOf(address(collateralTimelock)), 0, "CollateralTimelock should hold 0 NFTs");

        // Receipt token should be burned
        vm.expectRevert();
        collateralTimelock.ownerOf(receiptTokenId);
    }

    function test__Cancel_SuccessAfterDifferentNFTSetWithdrawn() public {
        address target = users.borrower;
        bytes32 context = keccak256("test-context-multiple-nft-sets");
        uint64 expiration = uint64(block.timestamp + 7 days);
        uint256[] memory withdrawnNftIds = new uint256[](1);
        withdrawnNftIds[0] = 1;
        uint256[] memory untouchedNftIds = new uint256[](1);
        untouchedNftIds[0] = 2;

        vm.startPrank(users.borrower);

        testNFT.mint(users.borrower, withdrawnNftIds[0]);
        testNFT.mint(users.borrower, untouchedNftIds[0]);
        testNFT.approve(address(collateralTimelock), withdrawnNftIds[0]);
        testNFT.approve(address(collateralTimelock), untouchedNftIds[0]);

        collateralTimelock.deposit(target, context, address(testNFT), withdrawnNftIds, expiration);
        collateralTimelock.deposit(target, context, address(testNFT), untouchedNftIds, expiration);

        vm.stopPrank();

        uint256 untouchedReceiptTokenId =
            collateralTimelock.depositTokenId(target, context, address(testNFT), untouchedNftIds);

        // Target withdraws the first NFT set
        vm.prank(target);
        collateralTimelock.withdraw(context, address(testNFT), withdrawnNftIds);

        assertEq(testNFT.ownerOf(withdrawnNftIds[0]), target, "Target should receive withdrawn NFT");
        assertEq(testNFT.ownerOf(untouchedNftIds[0]), address(collateralTimelock), "Untouched NFT should stay escrowed");

        vm.warp(expiration + 1);

        // Depositor cancels the untouched NFT set
        vm.prank(users.borrower);
        collateralTimelock.cancel(target, context, address(testNFT), untouchedNftIds);

        assertEq(testNFT.ownerOf(untouchedNftIds[0]), users.borrower, "Depositor should recover untouched NFT");

        vm.expectRevert();
        collateralTimelock.ownerOf(untouchedReceiptTokenId);
    }

    /*------------------------------------------------------------------------*/
    /* Test: cancel failures */
    /*------------------------------------------------------------------------*/

    function test__Cancel_RevertWhen_NotDepositor() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context-not-owner");
        uint64 expiration = uint64(block.timestamp + 7 days);
        uint256[] memory nftIds = new uint256[](1);
        nftIds[0] = 1;

        vm.startPrank(users.borrower);

        testNFT.mint(users.borrower, nftIds[0]);
        testNFT.approve(address(collateralTimelock), nftIds[0]);

        collateralTimelock.deposit(target, context, address(testNFT), nftIds, expiration);

        vm.stopPrank();

        // lender2 is not the depositor
        vm.prank(users.lender1);
        vm.expectRevert(ICollateralTimelock.InvalidCaller.selector);
        collateralTimelock.cancel(target, context, address(testNFT), nftIds);
    }

    function test__Cancel_RevertWhen_BeforeExpiration() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context-before-expiry");
        uint64 expiration = uint64(block.timestamp + 7 days);
        uint256[] memory nftIds = new uint256[](1);
        nftIds[0] = 1;

        vm.startPrank(users.borrower);

        testNFT.mint(users.borrower, nftIds[0]);
        testNFT.approve(address(collateralTimelock), nftIds[0]);

        collateralTimelock.deposit(target, context, address(testNFT), nftIds, expiration);

        // Cancel before expiration should fail
        vm.expectRevert(ICollateralTimelock.InvalidTimestamp.selector);
        collateralTimelock.cancel(target, context, address(testNFT), nftIds);

        vm.stopPrank();
    }

    function test__Cancel_RevertWhen_Twice() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context-cancel-twice");
        uint64 expiration = uint64(block.timestamp + 7 days);
        uint256[] memory nftIds = new uint256[](1);
        nftIds[0] = 1;

        vm.startPrank(users.borrower);

        testNFT.mint(users.borrower, nftIds[0]);
        testNFT.approve(address(collateralTimelock), nftIds[0]);

        collateralTimelock.deposit(target, context, address(testNFT), nftIds, expiration);

        vm.warp(expiration + 1);

        collateralTimelock.cancel(target, context, address(testNFT), nftIds);

        vm.expectRevert(ICollateralTimelock.InvalidDeposit.selector);
        collateralTimelock.cancel(target, context, address(testNFT), nftIds);

        vm.stopPrank();
    }

    function test__Cancel_RevertWhen_DepositDoesNotExist() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context-missing");
        uint256[] memory nftIds = new uint256[](1);
        nftIds[0] = 1;

        vm.prank(users.borrower);
        vm.expectRevert(ICollateralTimelock.InvalidDeposit.selector);
        collateralTimelock.cancel(target, context, address(testNFT), nftIds);
    }
}
