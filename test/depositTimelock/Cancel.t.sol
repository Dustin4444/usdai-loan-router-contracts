// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {BaseTest} from "../Base.t.sol";
import {IDepositTimelock} from "src/interfaces/IDepositTimelock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DepositTimelockCancelTest is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Test: cancel */
    /*------------------------------------------------------------------------*/

    function test__Cancel_Success() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18; // 100k USDai
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit first
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDAI, amount, expiration);

        // Warp past expiration
        vm.warp(expiration + 1);

        uint256 lender1BalanceBefore = IERC20(USDAI).balanceOf(users.lender1);

        // Cancel
        vm.expectEmit(true, true, true, true);
        emit IDepositTimelock.Canceled(users.lender1, target, context, USDAI, amount);
        depositTimelock.cancel(target, context);

        vm.stopPrank();

        // Verify deposit was deleted
        (,,, address token, uint256 depositedAmount, uint64 depositExpiration) =
            depositTimelock.depositInfo(depositTimelock.depositTokenId(users.lender1, target, context));

        assertEq(token, address(0), "Token should be zero after cancel");
        assertEq(depositedAmount, 0, "Amount should be zero after cancel");
        assertEq(depositExpiration, 0, "Expiration should be zero after cancel");

        // Verify tokens returned
        assertEq(IERC20(USDAI).balanceOf(users.lender1) - lender1BalanceBefore, amount, "Tokens should be returned");

        // Verify receipt token was burned
        assertEq(depositTimelock.balanceOf(users.lender1), 0, "Receipt token should be burned");
    }

    function test__Cancel_MultipleDeposits() public {
        address target = address(loanRouter);
        bytes32 context1 = keccak256("context-1");
        bytes32 context2 = keccak256("context-2");
        uint256 amount1 = 100_000 * 1e18;
        uint256 amount2 = 50_000 * 1e18;
        uint64 expiration = uint64(block.timestamp + 7 days);

        vm.startPrank(users.lender1);

        // Make two deposits
        depositTimelock.deposit(target, context1, USDAI, amount1, expiration);
        depositTimelock.deposit(target, context2, USDAI, amount2, expiration);

        // Warp past expiration
        vm.warp(expiration + 1);

        // Cancel first deposit
        depositTimelock.cancel(target, context1);

        // Verify first deposit cancelled
        (,,,, uint256 amount1After,) =
            depositTimelock.depositInfo(depositTimelock.depositTokenId(users.lender1, target, context1));
        assertEq(amount1After, 0, "First deposit should be cancelled");

        // Verify second deposit still exists
        (,,,, uint256 amount2After,) =
            depositTimelock.depositInfo(depositTimelock.depositTokenId(users.lender1, target, context2));
        assertEq(amount2After, amount2, "Second deposit should still exist");

        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: cancel failures */
    /*------------------------------------------------------------------------*/

    function test__Cancel_RevertWhen_NotExpired() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDAI, amount, expiration);

        // Try to cancel before expiration
        vm.expectRevert(IDepositTimelock.InvalidTimestamp.selector);
        depositTimelock.cancel(target, context);

        vm.stopPrank();
    }

    function test__Cancel_RevertWhen_AtExpiration() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDAI, amount, expiration);

        // Try to cancel exactly at expiration (should fail, need to be > expiration)
        vm.warp(expiration);

        vm.expectRevert(IDepositTimelock.InvalidTimestamp.selector);
        depositTimelock.cancel(target, context);

        vm.stopPrank();
    }

    function test__Cancel_RevertWhen_DepositDoesNotExist() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("nonexistent");

        vm.startPrank(users.lender1);

        vm.expectRevert(IDepositTimelock.InvalidDeposit.selector);
        depositTimelock.cancel(target, context);

        vm.stopPrank();
    }

    function test__Cancel_RevertWhen_ZeroTarget() public {
        bytes32 context = keccak256("test-context");

        vm.startPrank(users.lender1);
        vm.expectRevert(IDepositTimelock.InvalidAddress.selector);
        depositTimelock.cancel(address(0), context);
        vm.stopPrank();
    }

    function test__Cancel_RevertWhen_ZeroContext() public {
        address target = address(loanRouter);

        vm.startPrank(users.lender1);
        vm.expectRevert(IDepositTimelock.InvalidBytes32.selector);
        depositTimelock.cancel(target, bytes32(0));
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: cancel after withdrawal */
    /*------------------------------------------------------------------------*/

    function test__Cancel_AfterWithdrawal_ShouldFail() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 depositAmount = 100_000 * 1e18; // 100k USDai (18 decimals)
        uint256 withdrawAmount = 98_000 * 1e18; // 98k USDai
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDAI, depositAmount, expiration);
        vm.stopPrank();

        // Withdraw (simulating loan borrow)
        vm.startPrank(target);
        depositTimelock.withdraw(users.lender1, context, USDAI, withdrawAmount);
        vm.stopPrank();

        // Try to cancel after withdrawal (should fail because deposit no longer exists)
        vm.warp(expiration + 1);

        vm.startPrank(users.lender1);
        vm.expectRevert(IDepositTimelock.InvalidDeposit.selector);
        depositTimelock.cancel(target, context);
        vm.stopPrank();
    }
}
