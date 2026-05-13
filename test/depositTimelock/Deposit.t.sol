// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {BaseTest} from "../Base.t.sol";
import {IDepositTimelock} from "src/interfaces/IDepositTimelock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DepositTimelockDepositTest is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Test: deposit */
    /*------------------------------------------------------------------------*/

    function test__Deposit_Success() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18; // 100k USDai
        uint64 expiration = uint64(block.timestamp + 7 days);

        uint256 lender1BalanceBefore = IERC20(USDAI).balanceOf(users.lender1);

        vm.startPrank(users.lender1);
        vm.expectEmit(true, true, true, true);
        emit IDepositTimelock.Deposited(users.lender1, target, context, USDAI, amount, expiration);
        depositTimelock.deposit(target, context, USDAI, amount, expiration);
        vm.stopPrank();

        // Verify deposit was recorded
        (,,, address token, uint256 depositedAmount, uint64 depositExpiration) =
            depositTimelock.depositInfo(depositTimelock.depositTokenId(users.lender1, target, context));

        assertEq(token, USDAI, "Token should be USDai");
        assertEq(depositedAmount, amount, "Amount should match");
        assertEq(depositExpiration, expiration, "Expiration should match");

        // Verify tokens transferred
        assertEq(lender1BalanceBefore - IERC20(USDAI).balanceOf(users.lender1), amount, "Tokens should be transferred");

        // Verify receipt token was minted
        assertEq(
            depositTimelock.ownerOf(depositTimelock.depositTokenId(users.lender1, target, context)),
            users.lender1,
            "Receipt token should be owned by lender1"
        );
    }

    function test__Deposit_MultipleDepositors_SameContext() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("shared-context");
        uint256 amount1 = 50_000 * 1e18;
        uint256 amount2 = 75_000 * 1e18;
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Lender1 deposits
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDAI, amount1, expiration);
        vm.stopPrank();

        // Lender2 deposits with same context
        vm.startPrank(users.lender2);
        depositTimelock.deposit(target, context, USDAI, amount2, expiration);
        vm.stopPrank();

        // Verify both deposits exist independently
        (,,,, uint256 deposit1Amount,) =
            depositTimelock.depositInfo(depositTimelock.depositTokenId(users.lender1, target, context));
        (,,,, uint256 deposit2Amount,) =
            depositTimelock.depositInfo(depositTimelock.depositTokenId(users.lender2, target, context));

        assertEq(deposit1Amount, amount1, "Lender1 deposit should be recorded");
        assertEq(deposit2Amount, amount2, "Lender2 deposit should be recorded");

        // Verify receipt tokens were minted
        assertEq(
            depositTimelock.ownerOf(depositTimelock.depositTokenId(users.lender1, target, context)),
            users.lender1,
            "Receipt token should be owned by lender1"
        );
        assertEq(
            depositTimelock.ownerOf(depositTimelock.depositTokenId(users.lender2, target, context)),
            users.lender2,
            "Receipt token should be owned by lender2"
        );
    }

    function test__Deposit_DifferentContexts() public {
        address target = address(loanRouter);
        bytes32 context1 = keccak256("context-1");
        bytes32 context2 = keccak256("context-2");
        uint256 amount = 100_000 * 1e18;
        uint64 expiration = uint64(block.timestamp + 7 days);

        vm.startPrank(users.lender1);

        // Deposit with context1
        depositTimelock.deposit(target, context1, USDAI, amount, expiration);

        // Deposit with context2
        depositTimelock.deposit(target, context2, USDAI, amount, expiration);

        vm.stopPrank();

        // Verify both deposits exist
        (,,,, uint256 amount1,) =
            depositTimelock.depositInfo(depositTimelock.depositTokenId(users.lender1, target, context1));
        (,,,, uint256 amount2,) =
            depositTimelock.depositInfo(depositTimelock.depositTokenId(users.lender1, target, context2));

        assertEq(amount1, amount, "Context1 deposit should exist");
        assertEq(amount2, amount, "Context2 deposit should exist");
    }

    /*------------------------------------------------------------------------*/
    /* Test: deposit failures */
    /*------------------------------------------------------------------------*/

    function test__Deposit_RevertWhen_ZeroTarget() public {
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;
        uint64 expiration = uint64(block.timestamp + 7 days);

        vm.startPrank(users.lender1);
        vm.expectRevert(IDepositTimelock.InvalidAddress.selector);
        depositTimelock.deposit(address(0), context, USDAI, amount, expiration);
        vm.stopPrank();
    }

    function test__Deposit_RevertWhen_ZeroToken() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;
        uint64 expiration = uint64(block.timestamp + 7 days);

        vm.startPrank(users.lender1);
        vm.expectRevert(IDepositTimelock.InvalidAddress.selector);
        depositTimelock.deposit(target, context, address(0), amount, expiration);
        vm.stopPrank();
    }

    function test__Deposit_RevertWhen_ZeroAmount() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint64 expiration = uint64(block.timestamp + 7 days);

        vm.startPrank(users.lender1);
        vm.expectRevert(IDepositTimelock.InvalidAmount.selector);
        depositTimelock.deposit(target, context, USDAI, 0, expiration);
        vm.stopPrank();
    }

    function test__Deposit_RevertWhen_ZeroExpiration() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;

        vm.startPrank(users.lender1);
        vm.expectRevert(IDepositTimelock.InvalidAmount.selector);
        depositTimelock.deposit(target, context, USDAI, amount, 0);
        vm.stopPrank();
    }

    function test__Deposit_RevertWhen_ZeroContext() public {
        address target = address(loanRouter);
        uint256 amount = 100_000 * 1e18;
        uint64 expiration = uint64(block.timestamp + 7 days);

        vm.startPrank(users.lender1);
        vm.expectRevert(IDepositTimelock.InvalidBytes32.selector);
        depositTimelock.deposit(target, bytes32(0), USDAI, amount, expiration);
        vm.stopPrank();
    }

    function test__Deposit_RevertWhen_AlreadyExists() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;
        uint64 expiration = uint64(block.timestamp + 7 days);

        vm.startPrank(users.lender1);

        // First deposit
        depositTimelock.deposit(target, context, USDAI, amount, expiration);

        // Try to deposit again with same parameters
        vm.expectRevert(IDepositTimelock.InvalidDeposit.selector);
        depositTimelock.deposit(target, context, USDAI, amount, expiration);

        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: depositInfo getter */
    /*------------------------------------------------------------------------*/

    function test__DepositInfo_NonExistent() public view {
        address target = address(loanRouter);
        bytes32 context = keccak256("nonexistent");

        (,,, address token, uint256 amount, uint64 expiration) =
            depositTimelock.depositInfo(depositTimelock.depositTokenId(users.lender1, target, context));

        assertEq(token, address(0), "Token should be zero for nonexistent deposit");
        assertEq(amount, 0, "Amount should be zero for nonexistent deposit");
        assertEq(expiration, 0, "Expiration should be zero for nonexistent deposit");
    }

    /*------------------------------------------------------------------------*/
    /* Test: ERC721 transfers */
    /*------------------------------------------------------------------------*/

    function test__ERC721Transfers_Disabled() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;
        uint64 expiration = uint64(block.timestamp + 7 days);

        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDAI, amount, expiration);

        uint256 tokenId = depositTimelock.depositTokenId(users.lender1, target, context);

        vm.expectRevert();
        depositTimelock.approve(users.lender2, tokenId);

        vm.expectRevert();
        depositTimelock.transferFrom(users.lender1, users.lender2, tokenId);

        vm.expectRevert();
        depositTimelock.safeTransferFrom(users.lender1, users.lender2, tokenId, "");

        vm.stopPrank();
    }
}
