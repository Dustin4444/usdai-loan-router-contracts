// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {BaseTest} from "../Base.t.sol";
import {IDepositTimelock} from "src/interfaces/IDepositTimelock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DepositTimelockWithdrawTest is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Test: withdraw */
    /*------------------------------------------------------------------------*/

    function test__Withdraw_Success() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 depositAmount = 100_000 * 1e18; // 100k USDai (18 decimals)
        uint256 withdrawAmount = 98_000 * 1e18; // 98k USDai - simulates principal draw
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDAI, depositAmount, expiration);
        vm.stopPrank();

        uint256 targetBalanceBefore = IERC20(USDAI).balanceOf(target);
        uint256 depositorBalanceBefore = IERC20(USDAI).balanceOf(users.lender1);

        // Withdraw (called by target contract - the LoanRouter)
        vm.startPrank(target);
        uint256 withdrawnAmount = depositTimelock.withdraw(users.lender1, context, USDAI, withdrawAmount);
        vm.stopPrank();

        // Verify exact withdraw amount returned
        assertEq(withdrawnAmount, withdrawAmount, "Withdrawn amount should equal requested amount");

        // Verify target received correct amount
        assertEq(
            IERC20(USDAI).balanceOf(target) - targetBalanceBefore,
            withdrawAmount,
            "Target should receive withdraw amount"
        );

        // Verify refund sent to depositor
        uint256 expectedRefund = depositAmount - withdrawAmount;

        assertEq(
            IERC20(USDAI).balanceOf(users.lender1) - depositorBalanceBefore,
            expectedRefund,
            "Depositor should receive refund"
        );

        // Verify deposit was deleted
        (,,,, uint256 depositedAmount, uint64 depositExpiration) =
            depositTimelock.depositInfo(depositTimelock.depositTokenId(users.lender1, target, context));

        assertEq(depositedAmount, 0, "Amount should be zero after withdraw");
        assertEq(depositExpiration, 0, "Expiration should be zero after withdraw");

        // Verify receipt token was burned
        assertEq(depositTimelock.balanceOf(users.lender1), 0, "Receipt token should be burned");
    }

    function test__Withdraw_FullAmount_NoRefund() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context-full");
        uint256 depositAmount = 100_000 * 1e18;
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDAI, depositAmount, expiration);
        vm.stopPrank();

        uint256 depositorBalanceBefore = IERC20(USDAI).balanceOf(users.lender1);

        // Withdraw full amount
        vm.startPrank(target);
        depositTimelock.withdraw(users.lender1, context, USDAI, depositAmount);
        vm.stopPrank();

        // No refund when full amount withdrawn
        assertEq(IERC20(USDAI).balanceOf(users.lender1), depositorBalanceBefore, "No refund expected");
    }

    function test__Withdraw_BeforeExpiration() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 depositAmount = 100_000 * 1e18;
        uint256 withdrawAmount = 98_000 * 1e18;
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDAI, depositAmount, expiration);
        vm.stopPrank();

        // Warp to middle of timelock (before expiration)
        vm.warp(block.timestamp + 3 days);

        // Should be able to withdraw before expiration
        vm.startPrank(target);
        depositTimelock.withdraw(users.lender1, context, USDAI, withdrawAmount);
        vm.stopPrank();

        // Verify withdrawal succeeded
        (,,,, uint256 depositedAmount,) =
            depositTimelock.depositInfo(depositTimelock.depositTokenId(users.lender1, target, context));
        assertEq(depositedAmount, 0, "Deposit should be withdrawn");
    }

    /*------------------------------------------------------------------------*/
    /* Test: withdraw failures */
    /*------------------------------------------------------------------------*/

    function test__Withdraw_RevertWhen_AfterExpiration() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 depositAmount = 100_000 * 1e18;
        uint256 withdrawAmount = 100_000 * 1e18;
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDAI, depositAmount, expiration);
        vm.stopPrank();

        // Warp past expiration
        vm.warp(expiration + 1);

        // Try to withdraw after expiration (should fail)
        vm.startPrank(target);
        vm.expectRevert(IDepositTimelock.InvalidTimestamp.selector);
        depositTimelock.withdraw(users.lender1, context, USDAI, withdrawAmount);
        vm.stopPrank();
    }

    function test__Withdraw_RevertWhen_CallerIsNotTarget() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 depositAmount = 100_000 * 1e18;
        uint256 withdrawAmount = 100_000 * 1e18;
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDAI, depositAmount, expiration);
        vm.stopPrank();

        // The contract has no separate caller-vs-target access check: msg.sender feeds the depositTokenId
        // derivation, so a non-target caller looks up a different (nonexistent) deposit whose default
        // expiration is 0. The first revert encountered is therefore InvalidTimestamp (block.timestamp > 0),
        // not a dedicated access-control error.
        vm.startPrank(users.lender2);
        vm.expectRevert(IDepositTimelock.InvalidTimestamp.selector);
        depositTimelock.withdraw(users.lender1, context, USDAI, withdrawAmount);
        vm.stopPrank();
    }

    function test__Withdraw_RevertWhen_UnsupportedToken() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 depositAmount = 100_000 * 1e18;
        uint256 withdrawAmount = 100_000 * 1e6;
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit USDAI
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDAI, depositAmount, expiration);
        vm.stopPrank();

        // Withdraw with non-deposit token should fail
        vm.startPrank(target);
        vm.expectRevert(IDepositTimelock.UnsupportedToken.selector);
        depositTimelock.withdraw(users.lender1, context, USDC, withdrawAmount);
        vm.stopPrank();
    }

    function test__Withdraw_RevertWhen_DepositDoesNotExist() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("nonexistent");
        uint256 withdrawAmount = 100_000 * 1e18;

        vm.startPrank(target);
        vm.expectRevert(IDepositTimelock.InvalidTimestamp.selector);
        depositTimelock.withdraw(users.lender1, context, USDAI, withdrawAmount);
        vm.stopPrank();
    }

    function test__Withdraw_RevertWhen_ZeroContext() public {
        address target = address(loanRouter);
        uint256 withdrawAmount = 100_000 * 1e18;

        vm.startPrank(target);
        vm.expectRevert(IDepositTimelock.InvalidBytes32.selector);
        depositTimelock.withdraw(users.lender1, bytes32(0), USDAI, withdrawAmount);
        vm.stopPrank();
    }

    function test__Withdraw_RevertWhen_ZeroDepositor() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 withdrawAmount = 100_000 * 1e18;

        vm.startPrank(target);
        vm.expectRevert(IDepositTimelock.InvalidAddress.selector);
        depositTimelock.withdraw(address(0), context, USDAI, withdrawAmount);
        vm.stopPrank();
    }

    function test__Withdraw_RevertWhen_ZeroWithdrawToken() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 depositAmount = 100_000 * 1e18;
        uint256 withdrawAmount = 100_000 * 1e18;
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDAI, depositAmount, expiration);
        vm.stopPrank();

        vm.startPrank(target);
        vm.expectRevert(IDepositTimelock.InvalidAddress.selector);
        depositTimelock.withdraw(users.lender1, context, address(0), withdrawAmount);
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: withdraw twice should fail */
    /*------------------------------------------------------------------------*/

    function test__Withdraw_Twice_ShouldFail() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 depositAmount = 100_000 * 1e18;
        uint256 withdrawAmount = 98_000 * 1e18;
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDAI, depositAmount, expiration);
        vm.stopPrank();

        vm.startPrank(target);

        // First withdrawal
        depositTimelock.withdraw(users.lender1, context, USDAI, withdrawAmount);

        // Second withdrawal should fail (deposit deleted after first)
        vm.expectRevert(IDepositTimelock.InvalidTimestamp.selector);
        depositTimelock.withdraw(users.lender1, context, USDAI, withdrawAmount);

        vm.stopPrank();
    }
}
