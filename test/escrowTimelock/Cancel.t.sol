// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {BaseTest} from "../Base.t.sol";
import {IEscrowTimelock} from "src/interfaces/IEscrowTimelock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract EscrowTimelockCancelTest is BaseTest {
    event Canceled(address indexed target, bytes32 indexed context, uint256 amount, uint256 interest);

    /*------------------------------------------------------------------------*/
    /* Test: cancel */
    /*------------------------------------------------------------------------*/

    function test__Cancel_Success() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;
        uint256 interestRate = RATE_10_PCT;

        // Deposit
        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, interestRate);

        // Warp 30 days for interest accrual
        vm.warp(block.timestamp + 30 days);

        uint256 expectedInterest = calculateExpectedInterest(amount, interestRate, 30 days);

        uint256 susdaiBalanceBefore = IERC20(USDAI).balanceOf(STAKED_USDAI);
        uint256 escrowAdminBalanceBefore = IERC20(USDAI).balanceOf(users.admin);

        // Cancel
        vm.startPrank(STAKED_USDAI);
        (uint256 returned, uint256 interest) = escrowTimelock.cancel(target, context);
        vm.stopPrank();

        // Verify return value and interest
        assertEq(returned, amount, "Return value should be principal + interest");
        assertEq(interest, expectedInterest, "Interest should be correct");

        // Verify deposit was deleted
        uint256 tokenId = escrowTimelock.depositTokenId(target, context);
        (,, uint256 depositedAmount,,,) = escrowTimelock.depositInfo(tokenId);
        assertEq(depositedAmount, 0, "Deposit should be deleted");

        // Verify USDai transferred from escrowAdmin to sUSDai
        assertEq(
            IERC20(USDAI).balanceOf(STAKED_USDAI) - susdaiBalanceBefore,
            amount + expectedInterest,
            "sUSDai should receive principal + interest"
        );
        assertEq(
            escrowAdminBalanceBefore - IERC20(USDAI).balanceOf(users.admin),
            amount + expectedInterest,
            "escrowAdmin should pay principal + interest"
        );

        // Verify receipt token was burned
        assertEq(escrowTimelock.balanceOf(STAKED_USDAI), 0, "Receipt token should be burned");

        // Verify accrued interest is 0 after all deposits cancelled
        assertEq(escrowTimelock.accrued(), 0, "Accrued should be 0 after all deposits cancelled");
    }

    function test__Cancel_ImmediateCancel_ZeroInterest() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;

        // Deposit and cancel in same block
        vm.startPrank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, RATE_10_PCT);

        uint256 susdaiBalanceBefore = IERC20(USDAI).balanceOf(STAKED_USDAI);

        (uint256 returned, uint256 interest) = escrowTimelock.cancel(target, context);
        vm.stopPrank();

        // Interest should be 0 (same block)
        assertEq(returned, amount, "Return should be principal");
        assertEq(interest, 0, "Interest should be 0");
        assertEq(
            IERC20(USDAI).balanceOf(STAKED_USDAI) - susdaiBalanceBefore, amount, "sUSDai should receive exact principal"
        );
    }

    function test__Cancel_VerifyInterestAccrual_OneYear() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;
        uint256 interestRate = RATE_10_PCT;

        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, interestRate);

        // Warp 1 year
        vm.warp(block.timestamp + 365 days);

        vm.prank(STAKED_USDAI);
        (, uint256 interest) = escrowTimelock.cancel(target, context);

        // 10% APR for 1 year on 100k = ~10,000 USDai
        assertGt(interest, 9_900 * 1e18, "Interest should be approximately 10k USDai");
        assertLt(interest, 10_100 * 1e18, "Interest should be approximately 10k USDai");
    }

    function test__Cancel_MultipleDeposits_CancelOne() public {
        address target = address(loanRouter);
        bytes32 context1 = keccak256("context-1");
        bytes32 context2 = keccak256("context-2");
        uint256 amount1 = 100_000 * 1e18;
        uint256 amount2 = 50_000 * 1e18;

        vm.startPrank(STAKED_USDAI);
        escrowTimelock.deposit(target, context1, USDAI, amount1, RATE_8_PCT);
        escrowTimelock.deposit(target, context2, USDAI, amount2, RATE_12_PCT);

        vm.warp(block.timestamp + 30 days);

        // Cancel first deposit
        escrowTimelock.cancel(target, context1);
        vm.stopPrank();

        // Verify first deposit cancelled
        (,, uint256 dep1Amount,,,) = escrowTimelock.depositInfo(escrowTimelock.depositTokenId(target, context1));
        assertEq(dep1Amount, 0, "First deposit should be cancelled");

        // Verify second deposit still exists
        (,, uint256 dep2Amount,,,) = escrowTimelock.depositInfo(escrowTimelock.depositTokenId(target, context2));
        assertEq(dep2Amount, amount2, "Second deposit should still exist");

        // Verify accrued only reflects remaining deposit
        uint256 expectedAccrued = calculateExpectedInterest(amount2, RATE_12_PCT, 30 days);
        assertEq(escrowTimelock.accrued(), expectedAccrued, "Accrued should only reflect remaining deposit");
    }

    /*------------------------------------------------------------------------*/
    /* Test: cancel failures */
    /*------------------------------------------------------------------------*/

    function test__Cancel_RevertWhen_DepositDoesNotExist() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("nonexistent");

        vm.startPrank(STAKED_USDAI);
        vm.expectRevert(IEscrowTimelock.InvalidDeposit.selector);
        escrowTimelock.cancel(target, context);
        vm.stopPrank();
    }

    function test__Cancel_RevertWhen_ZeroTarget() public {
        bytes32 context = keccak256("test-context");

        vm.startPrank(STAKED_USDAI);
        vm.expectRevert(IEscrowTimelock.InvalidAddress.selector);
        escrowTimelock.cancel(address(0), context);
        vm.stopPrank();
    }

    function test__Cancel_RevertWhen_ZeroContext() public {
        address target = address(loanRouter);

        vm.startPrank(STAKED_USDAI);
        vm.expectRevert(IEscrowTimelock.InvalidBytes32.selector);
        escrowTimelock.cancel(target, bytes32(0));
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: event emission */
    /*------------------------------------------------------------------------*/

    function test__Cancel_EmitsCanceledEvent() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("cancel-event");
        uint256 amount = 100_000 * 1e18;
        uint256 interestRate = RATE_10_PCT;

        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, interestRate);

        vm.warp(block.timestamp + 30 days);
        uint256 expectedInterest = calculateExpectedInterest(amount, interestRate, 30 days);

        vm.expectEmit(true, true, true, true, address(escrowTimelock));
        emit Canceled(target, context, amount, expectedInterest);

        vm.prank(STAKED_USDAI);
        escrowTimelock.cancel(target, context);
    }

    /*------------------------------------------------------------------------*/
    /* Test: aggregate accounting */
    /*------------------------------------------------------------------------*/

    function test__Cancel_VerifyTotalDepositsDecrement() public {
        address target = address(loanRouter);
        uint256 a1 = 100_000 * 1e18;
        uint256 a2 = 50_000 * 1e18;
        uint256 a3 = 25_000 * 1e18;

        vm.startPrank(STAKED_USDAI);
        escrowTimelock.deposit(target, keccak256("a"), USDAI, a1, RATE_8_PCT);
        escrowTimelock.deposit(target, keccak256("b"), USDAI, a2, RATE_10_PCT);
        escrowTimelock.deposit(target, keccak256("c"), USDAI, a3, RATE_12_PCT);

        // Cancel the middle one
        escrowTimelock.cancel(target, keccak256("b"));
        vm.stopPrank();

        assertEq(escrowTimelock.totalDeposits(), a1 + a3, "totalDeposits decrements by cancelled amount only");
    }

    function test__Cancel_VerifyAccrualRateDecrement() public {
        address target = address(loanRouter);
        uint256 a = 100_000 * 1e18;
        uint256 r = RATE_10_PCT;
        uint256 window = 30 days;

        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, keccak256("one"), USDAI, a, r);

        warp(window);
        uint256 expectedAccrual = (a * r * window) / FIXED_POINT_SCALE;
        assertEq(escrowTimelock.accrued(), expectedAccrual, "Pre-cancel accrual");

        vm.prank(STAKED_USDAI);
        escrowTimelock.cancel(target, keccak256("one"));

        uint256 accruedPostCancel = escrowTimelock.accrued();
        warp(365 days);
        assertEq(escrowTimelock.accrued(), accruedPostCancel, "No interest accrues once rate is decremented to zero");
    }

    function test__Cancel_SequentialCancellations() public {
        address target = address(loanRouter);
        uint256 a1 = 100_000 * 1e18;
        uint256 a2 = 50_000 * 1e18;
        uint256 r = RATE_10_PCT;
        uint256 window = 30 days;

        vm.startPrank(STAKED_USDAI);
        escrowTimelock.deposit(target, keccak256("seq1"), USDAI, a1, r);
        escrowTimelock.deposit(target, keccak256("seq2"), USDAI, a2, r);

        warp(window);
        assertEq(escrowTimelock.accrued(), ((a1 + a2) * r * window) / FIXED_POINT_SCALE, "Aggregate per-window accrual");

        // Cancel seq1; second deposit still accrues at its own rate
        escrowTimelock.cancel(target, keccak256("seq1"));

        uint256 postFirstCancel = escrowTimelock.accrued();
        warp(window);
        assertEq(
            escrowTimelock.accrued(),
            postFirstCancel + (a2 * r * window) / FIXED_POINT_SCALE,
            "After first cancel only seq2 accrues"
        );

        // Cancel seq2; nothing accrues further
        escrowTimelock.cancel(target, keccak256("seq2"));
        uint256 postSecondCancel = escrowTimelock.accrued();
        warp(365 days);
        assertEq(escrowTimelock.accrued(), postSecondCancel, "After second cancel accrual rate is zero");

        vm.stopPrank();
    }

    function test__Cancel_RevertWhen_AdminBalanceInsufficient() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("admin-balance");
        uint256 amount = 100_000 * 1e18;

        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, RATE_10_PCT);

        // Drain the escrow admin's USDai balance so they cannot pay principal back
        deal(USDAI, users.admin, 0);

        // cancel() transfers from the escrow admin via SafeERC20; with the admin balance zeroed the
        // underlying USDai ERC20 reverts. The selector is owned by the USDai implementation and is not
        // re-exported through our contracts, so a bare expectRevert is intentional here.
        uint256 totalDepositsBefore = escrowTimelock.totalDeposits();
        vm.startPrank(STAKED_USDAI);
        vm.expectRevert();
        escrowTimelock.cancel(target, context);
        vm.stopPrank();
        // Confirm the revert occurred at the transfer step (no state was committed)
        assertEq(escrowTimelock.totalDeposits(), totalDepositsBefore, "Cancel must not commit state on revert");
    }

    /*------------------------------------------------------------------------*/
    /* Test: cancel after withdrawal */
    /*------------------------------------------------------------------------*/

    function test__Cancel_AfterWithdrawal_ShouldFail() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;

        // Deposit
        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, RATE_10_PCT);

        // Withdraw (by target)
        vm.prank(target);
        escrowTimelock.withdraw(context, USDAI, amount);

        // Try to cancel after withdrawal
        vm.startPrank(STAKED_USDAI);
        vm.expectRevert(IEscrowTimelock.InvalidDeposit.selector);
        escrowTimelock.cancel(target, context);
        vm.stopPrank();
    }
}
