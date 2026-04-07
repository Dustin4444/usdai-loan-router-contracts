// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {BaseTest} from "../Base.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {IEscrowTimelock} from "src/interfaces/IEscrowTimelock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {EscrowTimelock} from "src/EscrowTimelock.sol";
import {EscrowTimelockHooksMock} from "../mocks/EscrowTimelockHooksMock.sol";

contract EscrowTimelockWithdrawTest is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Test: withdraw */
    /*------------------------------------------------------------------------*/

    function test__Withdraw_Success() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;
        uint256 interestRate = RATE_10_PCT;

        // Deposit
        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, interestRate);

        // Warp 30 days
        vm.warp(block.timestamp + 30 days);

        uint256 expectedInterest = calculateExpectedInterest(amount, interestRate, 30 days);
        uint256 susdaiBalanceBefore = IERC20(USDAI).balanceOf(STAKED_USDAI);
        uint256 escrowAdminBalanceBefore = IERC20(USDAI).balanceOf(users.admin);

        // Withdraw (called by target)
        vm.startPrank(target);
        (uint256 withdrawnAmount, uint256 withdrawnInterest) = escrowTimelock.withdraw(context, USDAI, amount);
        vm.stopPrank();

        // Verify return values
        assertEq(withdrawnAmount, amount, "Withdrawn amount should equal deposited amount");
        assertEq(withdrawnInterest, expectedInterest, "Interest return should match expected");

        // Verify interest transferred from escrowAdmin to sUSDai
        assertEq(
            IERC20(USDAI).balanceOf(STAKED_USDAI) - susdaiBalanceBefore,
            expectedInterest,
            "sUSDai should receive interest"
        );
        assertEq(
            escrowAdminBalanceBefore - IERC20(USDAI).balanceOf(users.admin),
            expectedInterest,
            "escrowAdmin should pay interest"
        );

        // Verify deposit was deleted
        uint256 tokenId = escrowTimelock.depositTokenId(target, context);
        (,, uint256 depositedAmount,,,) = escrowTimelock.depositInfo(tokenId);
        assertEq(depositedAmount, 0, "Deposit should be deleted");

        // Verify receipt token was burned
        assertEq(escrowTimelock.balanceOf(STAKED_USDAI), 0, "Receipt token should be burned");

        // Verify accrued is 0 after all withdrawals
        assertEq(escrowTimelock.accrued(), 0, "Accrued should be 0 after all withdrawals");
    }

    function test__Withdraw_SameBlock_ZeroInterest() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;

        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, RATE_10_PCT);

        uint256 susdaiBalanceBefore = IERC20(USDAI).balanceOf(STAKED_USDAI);
        uint256 escrowAdminBalanceBefore = IERC20(USDAI).balanceOf(users.admin);

        // Withdraw in same block
        vm.prank(target);
        (uint256 withdrawnAmount, uint256 withdrawnInterest) = escrowTimelock.withdraw(context, USDAI, amount);

        // Verify return values
        assertEq(withdrawnAmount, amount, "Withdrawn amount should equal deposited amount");
        assertEq(withdrawnInterest, 0, "Interest return should be zero in same block");

        // No interest should be transferred
        assertEq(IERC20(USDAI).balanceOf(STAKED_USDAI), susdaiBalanceBefore, "No USDai should be transferred");
        assertEq(IERC20(USDAI).balanceOf(users.admin), escrowAdminBalanceBefore, "escrowAdmin should not pay");
    }

    function test__Withdraw_VerifyInterestPayment_OneYear() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;
        uint256 interestRate = RATE_10_PCT;

        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, interestRate);

        vm.warp(block.timestamp + 365 days);

        uint256 susdaiBalanceBefore = IERC20(USDAI).balanceOf(STAKED_USDAI);

        vm.prank(target);
        escrowTimelock.withdraw(context, USDAI, amount);

        uint256 interestReceived = IERC20(USDAI).balanceOf(STAKED_USDAI) - susdaiBalanceBefore;

        // 10% APR for 1 year on 100k = ~10,000 USDai
        assertGt(interestReceived, 9_900 * 1e18, "Interest should be approximately 10k USDai");
        assertLt(interestReceived, 10_100 * 1e18, "Interest should be approximately 10k USDai");
    }

    function test__Withdraw_EmitsWithdrawnEvent() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;
        uint256 interestRate = RATE_10_PCT;

        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, interestRate);

        vm.warp(block.timestamp + 30 days);

        uint256 expectedInterest = calculateExpectedInterest(amount, interestRate, 30 days);

        // Use vm.recordLogs to verify the Withdrawn event
        vm.recordLogs();

        vm.prank(target);
        escrowTimelock.withdraw(context, USDAI, amount);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Find the Withdrawn event
        bytes32 withdrawnSig = keccak256("Withdrawn(address,bytes32,uint256,uint256,uint256)");
        bool foundWithdrawn;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == withdrawnSig) {
                foundWithdrawn = true;
                // Verify indexed params
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(target))), "withdrawer should be target");
                assertEq(logs[i].topics[2], context, "context should match");
                // Verify non-indexed params
                (uint256 depositAmount, uint256 withdrawAmount, uint256 interest) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(depositAmount, amount, "deposit amount should match");
                assertEq(withdrawAmount, amount, "withdraw amount should match");
                assertEq(interest, expectedInterest, "interest should match");
                break;
            }
        }
        assertTrue(foundWithdrawn, "Withdrawn event should be emitted");
    }

    function test__Withdraw_MultipleDeposits_WithdrawOne() public {
        address target = address(loanRouter);
        bytes32 context1 = keccak256("context-1");
        bytes32 context2 = keccak256("context-2");
        uint256 amount1 = 100_000 * 1e18;
        uint256 amount2 = 50_000 * 1e18;

        vm.startPrank(STAKED_USDAI);
        escrowTimelock.deposit(target, context1, USDAI, amount1, RATE_8_PCT);
        escrowTimelock.deposit(target, context2, USDAI, amount2, RATE_12_PCT);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);

        // Withdraw first deposit only
        vm.prank(target);
        escrowTimelock.withdraw(context1, USDAI, amount1);

        // First deposit deleted
        (,, uint256 dep1Amount,,,) = escrowTimelock.depositInfo(escrowTimelock.depositTokenId(target, context1));
        assertEq(dep1Amount, 0, "First deposit should be deleted");

        // Second deposit still exists
        (,, uint256 dep2Amount,,,) = escrowTimelock.depositInfo(escrowTimelock.depositTokenId(target, context2));
        assertEq(dep2Amount, amount2, "Second deposit should still exist");

        // Accrued only reflects remaining deposit
        uint256 expectedAccrued = calculateExpectedInterest(amount2, RATE_12_PCT, 30 days);
        assertEq(escrowTimelock.accrued(), expectedAccrued, "Accrued should only reflect remaining deposit");
    }

    /*------------------------------------------------------------------------*/
    /* Test: withdraw failures */
    /*------------------------------------------------------------------------*/

    function test__Withdraw_RevertWhen_CallerIsNotTarget() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;

        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, RATE_10_PCT);

        // EscrowTimelock has no dedicated access-control branch for non-target callers: msg.sender feeds the
        // tokenId derivation, so a non-target caller resolves to a different (empty) deposit and hits
        // InvalidDeposit on the existence check.
        vm.startPrank(users.lender1);
        vm.expectRevert(IEscrowTimelock.InvalidDeposit.selector);
        escrowTimelock.withdraw(context, USDAI, amount);
        vm.stopPrank();
    }

    function test__Withdraw_RevertWhen_DepositDoesNotExist() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("nonexistent");
        uint256 amount = 100_000 * 1e18;

        vm.startPrank(target);
        vm.expectRevert(IEscrowTimelock.InvalidDeposit.selector);
        escrowTimelock.withdraw(context, USDAI, amount);
        vm.stopPrank();
    }

    function test__Withdraw_RevertWhen_ZeroContext() public {
        address target = address(loanRouter);
        uint256 amount = 100_000 * 1e18;

        vm.startPrank(target);
        vm.expectRevert(IEscrowTimelock.InvalidBytes32.selector);
        escrowTimelock.withdraw(bytes32(0), USDAI, amount);
        vm.stopPrank();
    }

    function test__Withdraw_RevertWhen_AmountMismatch() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;

        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, RATE_10_PCT);

        // Passing any amount other than the exact deposited amount should revert
        vm.startPrank(target);
        vm.expectRevert(IEscrowTimelock.InvalidAmount.selector);
        escrowTimelock.withdraw(context, USDAI, amount - 1);
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: withdraw twice should fail */
    /*------------------------------------------------------------------------*/

    function test__Withdraw_Twice_ShouldFail() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;

        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, RATE_10_PCT);

        vm.startPrank(target);

        // First withdrawal
        escrowTimelock.withdraw(context, USDAI, amount);

        // Second withdrawal should fail (deposit deleted after first)
        vm.expectRevert(IEscrowTimelock.InvalidDeposit.selector);
        escrowTimelock.withdraw(context, USDAI, amount);

        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: aggregate accounting */
    /*------------------------------------------------------------------------*/

    function test__Withdraw_StorageDeleted() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("delete-check");
        uint256 amount = 100_000 * 1e18;

        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, RATE_10_PCT);

        uint256 tokenId = escrowTimelock.depositTokenId(target, context);
        (address t_, bytes32 c_, uint256 a_, uint256 r_, uint64 ts_,) = escrowTimelock.depositInfo(tokenId);
        require(a_ != 0 && t_ != address(0) && c_ != bytes32(0) && r_ != 0 && ts_ != 0, "precondition");

        vm.prank(target);
        escrowTimelock.withdraw(context, USDAI, amount);

        (address t2, bytes32 c2, uint256 a2, uint256 r2, uint64 ts2, uint256 i2) = escrowTimelock.depositInfo(tokenId);
        assertEq(t2, address(0), "target cleared");
        assertEq(c2, bytes32(0), "context cleared");
        assertEq(a2, 0, "amount cleared");
        assertEq(r2, 0, "interestRate cleared");
        assertEq(ts2, 0, "timestamp cleared");
        assertEq(i2, 0, "interest cleared");
    }

    function test__Withdraw_VerifyTotalDepositsDecrement() public {
        address target = address(loanRouter);
        uint256 a1 = 100_000 * 1e18;
        uint256 a2 = 50_000 * 1e18;
        uint256 a3 = 25_000 * 1e18;

        vm.startPrank(STAKED_USDAI);
        escrowTimelock.deposit(target, keccak256("a"), USDAI, a1, RATE_8_PCT);
        escrowTimelock.deposit(target, keccak256("b"), USDAI, a2, RATE_10_PCT);
        escrowTimelock.deposit(target, keccak256("c"), USDAI, a3, RATE_12_PCT);
        vm.stopPrank();

        // Withdraw the middle one
        vm.prank(target);
        escrowTimelock.withdraw(keccak256("b"), USDAI, a2);

        assertEq(escrowTimelock.totalDeposits(), a1 + a3, "totalDeposits decrements by withdrawn amount only");
    }

    function test__Withdraw_VerifyAccrualRateDecrement() public {
        address target = address(loanRouter);
        uint256 a = 100_000 * 1e18;
        uint256 r = RATE_10_PCT;

        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, keccak256("only"), USDAI, a, r);

        vm.warp(block.timestamp + 1);
        uint256 perSecond = (a * r) / FIXED_POINT_SCALE;
        assertEq(escrowTimelock.accrued(), perSecond, "Pre-withdraw accrual");

        vm.prank(target);
        escrowTimelock.withdraw(keccak256("only"), USDAI, a);

        // After withdraw, accrual rate is decremented to zero so no further interest accrues
        uint256 postWithdraw = escrowTimelock.accrued();
        vm.warp(block.timestamp + 365 days);
        assertEq(escrowTimelock.accrued(), postWithdraw, "No interest accrues after rate decrement");
    }

    function test__Withdraw_RevertWhen_AdminBalanceInsufficientForInterest() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("admin-balance");
        uint256 amount = 100_000 * 1e18;

        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, RATE_10_PCT);

        // Accrue some interest, then drain the admin
        vm.warp(block.timestamp + 30 days);
        deal(USDAI, users.admin, 0);

        vm.startPrank(target);
        vm.expectRevert();
        escrowTimelock.withdraw(context, USDAI, amount);
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: hook callback */
    /*------------------------------------------------------------------------*/

    function _deployEscrowWithMock(
        EscrowTimelockHooksMock.Mode mode
    ) internal returns (EscrowTimelock hookEscrow, EscrowTimelockHooksMock mock) {
        mock = new EscrowTimelockHooksMock(mode);

        vm.startPrank(users.deployer);
        EscrowTimelock impl = new EscrowTimelock(USDAI, address(mock), users.admin);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl), address(users.admin), abi.encodeWithSignature("initialize(address)", users.deployer)
        );
        hookEscrow = EscrowTimelock(address(proxy));
        vm.stopPrank();

        // Fund the mock with USDai and have it approve the new escrow
        deal(USDAI, address(mock), 1_000_000 * 1e18);
        mock.approveSpender(USDAI, address(hookEscrow), type(uint256).max);

        // Admin already holds USDai; approve the new escrow for interest payments
        vm.prank(users.admin);
        IERC20(USDAI).approve(address(hookEscrow), type(uint256).max);
    }

    function test__Withdraw_InvokesHookCallback_OnConformingDepositor() public {
        (EscrowTimelock hookEscrow, EscrowTimelockHooksMock mock) =
            _deployEscrowWithMock(EscrowTimelockHooksMock.Mode.Record);

        address target = address(loanRouter);
        bytes32 context = keccak256("hook-record");
        uint256 amount = 100_000 * 1e18;
        uint256 interestRate = RATE_10_PCT;

        vm.prank(address(mock));
        hookEscrow.deposit(target, context, USDAI, amount, interestRate);

        vm.warp(block.timestamp + 30 days);
        uint256 expectedInterest = calculateExpectedInterest(amount, interestRate, 30 days);

        vm.prank(target);
        hookEscrow.withdraw(context, USDAI, amount);

        assertEq(mock.callCount(), 1, "Hook invoked once");
        (
            address recordedTarget,
            bytes32 recordedContext,
            address recordedToken,
            uint256 recordedAmount,
            uint256 recordedInterest
        ) = mock.lastCall();
        assertEq(recordedTarget, target, "hook target param");
        assertEq(recordedContext, context, "hook context param");
        assertEq(recordedToken, USDAI, "hook token param");
        assertEq(recordedAmount, amount, "hook amount param");
        assertEq(recordedInterest, expectedInterest, "hook interest param");
    }

    function test__Withdraw_HookSkippedWhenDepositorDoesNotSupportInterface() public {
        (EscrowTimelock hookEscrow, EscrowTimelockHooksMock mock) =
            _deployEscrowWithMock(EscrowTimelockHooksMock.Mode.DisableInterface);

        address target = address(loanRouter);
        bytes32 context = keccak256("hook-no-iface");
        uint256 amount = 100_000 * 1e18;

        vm.prank(address(mock));
        hookEscrow.deposit(target, context, USDAI, amount, RATE_10_PCT);

        vm.warp(block.timestamp + 30 days);

        vm.prank(target);
        hookEscrow.withdraw(context, USDAI, amount);

        assertEq(mock.callCount(), 0, "Hook not invoked when ERC165 reports unsupported");
    }

    // The natspec on IEscrowTimelockHooks claims the hook call is best-effort, but the current
    // implementation does not wrap the call in try/catch. This test pins the current behavior:
    // a revert inside the hook bubbles up and the entire withdrawal aborts.
    function test__Withdraw_RevertsWhenHookReverts() public {
        (EscrowTimelock hookEscrow, EscrowTimelockHooksMock mock) =
            _deployEscrowWithMock(EscrowTimelockHooksMock.Mode.Revert);

        address target = address(loanRouter);
        bytes32 context = keccak256("hook-revert");
        uint256 amount = 100_000 * 1e18;

        vm.prank(address(mock));
        hookEscrow.deposit(target, context, USDAI, amount, RATE_10_PCT);

        vm.warp(block.timestamp + 30 days);

        vm.startPrank(target);
        vm.expectRevert(bytes("hook reverted"));
        hookEscrow.withdraw(context, USDAI, amount);
        vm.stopPrank();
    }
}
