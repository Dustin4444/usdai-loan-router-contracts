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
        uint256 minWithdrawAmount = 98_000 * 1e6; // 98k USDC (6 decimals) - allow 2% slippage
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDAI, depositAmount, expiration);
        vm.stopPrank();

        uint256 targetBalanceBefore = IERC20(USDC).balanceOf(target);

        // Withdraw (called by target contract - the LoanRouter)
        vm.startPrank(target);
        uint256 withdrawnAmount = depositTimelock.withdraw(context, users.lender1, USDC, minWithdrawAmount, "");
        vm.stopPrank();

        // Verify withdrawn amount is approximately 100k USDC (allowing slippage)
        assertGe(withdrawnAmount, minWithdrawAmount, "Should receive at least minimum amount");
        assertLe(withdrawnAmount, 100_000 * 1e6, "Should not exceed nominal amount");

        // Verify target received USDC
        uint256 targetBalanceAfter = IERC20(USDC).balanceOf(target);
        assertEq(targetBalanceAfter - targetBalanceBefore, withdrawnAmount, "Target should receive withdrawn amount");

        // Verify deposit was deleted
        (,,, address token, uint256 depositedAmount, uint64 depositExpiration) =
            depositTimelock.depositInfo(depositTimelock.depositTokenId(users.lender1, target, context));

        assertEq(token, address(0), "Token should be zero after withdraw");
        assertEq(depositedAmount, 0, "Amount should be zero after withdraw");
        assertEq(depositExpiration, 0, "Expiration should be zero after withdraw");

        // Verify receipt token was burned
        assertEq(depositTimelock.balanceOf(users.lender1), 0, "Receipt token should be burned");
    }

    function test__Withdraw_BeforeExpiration() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 depositAmount = 100_000 * 1e18; // 100k USDai (18 decimals)
        uint256 minWithdrawAmount = 98_000 * 1e6; // 98k USDC (6 decimals) - allow 2% slippage
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDAI, depositAmount, expiration);
        vm.stopPrank();

        // Warp to middle of timelock (before expiration)
        vm.warp(block.timestamp + 3 days);

        // Should be able to withdraw before expiration
        vm.startPrank(target);
        depositTimelock.withdraw(context, users.lender1, USDC, minWithdrawAmount, "");
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
        uint256 depositAmount = 100_000 * 1e18; // 100k USDai (18 decimals)
        uint256 minWithdrawAmount = 100_000 * 1e6; // 100k USDC (6 decimals)
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
        depositTimelock.withdraw(context, users.lender1, USDC, minWithdrawAmount, "");
        vm.stopPrank();
    }

    function test__Withdraw_RevertWhen_NotTarget() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 depositAmount = 100_000 * 1e18; // 100k USDai (18 decimals)
        uint256 minWithdrawAmount = 100_000 * 1e6; // 100k USDC (6 decimals)
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDAI, depositAmount, expiration);
        vm.stopPrank();

        // Try to withdraw as wrong address (not target)
        vm.startPrank(users.lender2);
        // This will fail because the deposit doesn't exist for this msg.sender
        vm.expectRevert(IDepositTimelock.InvalidTimestamp.selector);
        depositTimelock.withdraw(context, users.lender1, USDC, minWithdrawAmount, "");
        vm.stopPrank();
    }

    function test__Withdraw_RevertWhen_UnsupportedToken() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 depositAmount = 100_000 * 1e6; // 100k USDT (6 decimals)
        uint256 minWithdrawAmount = 100_000 * 1e18; // 100k USDAI (18 decimals)
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Remove swap adapter for USDT
        vm.startPrank(users.deployer);
        depositTimelock.removeSwapAdapter(USDT);
        vm.stopPrank();

        // Deposit USDT
        vm.startPrank(users.lender1);
        IERC20(USDT).approve(address(depositTimelock), depositAmount);
        depositTimelock.deposit(target, context, USDT, depositAmount, expiration);
        vm.stopPrank();

        vm.startPrank(target);
        vm.expectRevert(IDepositTimelock.UnsupportedToken.selector);
        depositTimelock.withdraw(context, users.lender1, USDAI, minWithdrawAmount, "");
        vm.stopPrank();
    }

    function test__Withdraw_RevertWhen_DepositDoesNotExist() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("nonexistent");
        uint256 minWithdrawAmount = 100_000 * 1e6; // 100k USDC (6 decimals)

        vm.startPrank(target);
        vm.expectRevert(IDepositTimelock.InvalidTimestamp.selector);
        depositTimelock.withdraw(context, users.lender1, USDC, minWithdrawAmount, "");
        vm.stopPrank();
    }

    function test__Withdraw_RevertWhen_ZeroContext() public {
        address target = address(loanRouter);
        uint256 minWithdrawAmount = 100_000 * 1e6; // 100k USDC (6 decimals)

        vm.startPrank(target);
        vm.expectRevert(IDepositTimelock.InvalidBytes32.selector);
        depositTimelock.withdraw(bytes32(0), users.lender1, USDC, minWithdrawAmount, "");
        vm.stopPrank();
    }

    function test__Withdraw_RevertWhen_ZeroDepositor() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 minWithdrawAmount = 100_000 * 1e6; // 100k USDC (6 decimals)

        vm.startPrank(target);
        vm.expectRevert(IDepositTimelock.InvalidAddress.selector);
        depositTimelock.withdraw(context, address(0), USDC, minWithdrawAmount, "");
        vm.stopPrank();
    }

    function test__Withdraw_RevertWhen_ZeroWithdrawToken() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 depositAmount = 100_000 * 1e18; // 100k USDai (18 decimals)
        uint256 minWithdrawAmount = 100_000 * 1e6; // 100k USDC (6 decimals)
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDAI, depositAmount, expiration);
        vm.stopPrank();

        vm.startPrank(target);
        vm.expectRevert(IDepositTimelock.InvalidAddress.selector);
        depositTimelock.withdraw(context, users.lender1, address(0), minWithdrawAmount, "");
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: withdraw twice should fail */
    /*------------------------------------------------------------------------*/

    function test__Withdraw_Twice_ShouldFail() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 depositAmount = 100_000 * 1e18; // 100k USDai (18 decimals)
        uint256 minWithdrawAmount = 98_000 * 1e6; // 98k USDC (6 decimals) - allow 2% slippage
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDAI, depositAmount, expiration);
        vm.stopPrank();

        vm.startPrank(target);

        // First withdrawal
        depositTimelock.withdraw(context, users.lender1, USDC, minWithdrawAmount, "");

        // Second withdrawal should fail (deposit no longer exists)
        vm.expectRevert(IDepositTimelock.InvalidTimestamp.selector);
        depositTimelock.withdraw(context, users.lender1, USDC, minWithdrawAmount, "");

        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: withdraw with UniswapV3SwapAdapter */
    /*------------------------------------------------------------------------*/

    function test__Withdraw_WithUniswapV3_Success() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context-uniswap");
        uint256 depositAmount = 100_000 * 1e6; // 100k USDC (6 decimals)
        uint256 minWithdrawAmount = 99_000 * 1e6; // 98k USDT (6 decimals) - allow 2% slippage
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit USDC
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDC, depositAmount, expiration);
        vm.stopPrank();

        uint256 targetBalanceBefore = IERC20(USDT).balanceOf(target);

        // Encode UniswapV3 path: USDT (output) - fee - USDC (input)
        // Fee tier: 100 (0.01% - common for stablecoin pairs)
        bytes memory path = abi.encodePacked(USDT, uint24(100), USDC);

        // Withdraw to USDT using UniswapV3 (called by target contract - the LoanRouter)
        vm.startPrank(target);
        uint256 withdrawnAmount = depositTimelock.withdraw(context, users.lender1, USDT, minWithdrawAmount, path);
        vm.stopPrank();

        // Verify withdrawn amount is approximately 100k USDT (allowing slippage)
        assertGe(withdrawnAmount, minWithdrawAmount, "Should receive at least minimum amount");
        assertLe(withdrawnAmount, 100_000 * 1e6, "Should not exceed nominal amount");

        // Verify target received USDT
        uint256 targetBalanceAfter = IERC20(USDT).balanceOf(target);
        assertEq(targetBalanceAfter - targetBalanceBefore, withdrawnAmount, "Target should receive withdrawn amount");

        // Verify deposit was deleted
        (,,, address token, uint256 depositedAmount, uint64 depositExpiration) =
            depositTimelock.depositInfo(depositTimelock.depositTokenId(users.lender1, target, context));

        assertEq(token, address(0), "Token should be zero after withdraw");
        assertEq(depositedAmount, 0, "Amount should be zero after withdraw");
        assertEq(depositExpiration, 0, "Expiration should be zero after withdraw");

        // Verify receipt token was burned
        assertEq(depositTimelock.balanceOf(users.lender1), 0, "Receipt token should be burned");
    }

    function test__Withdraw_WithUniswapV3_BeforeExpiration() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context-uniswap");
        uint256 depositAmount = 100_000 * 1e6; // 100k USDC (6 decimals)
        uint256 minWithdrawAmount = 98_000 * 1e6; // 98k USDT (6 decimals) - allow 2% slippage
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit USDC
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDC, depositAmount, expiration);
        vm.stopPrank();

        // Warp to middle of timelock (before expiration)
        vm.warp(block.timestamp + 3 days);

        // Encode UniswapV3 path: USDT (output) - fee - USDC (input)
        bytes memory path = abi.encodePacked(USDT, uint24(100), USDC);

        // Should be able to withdraw before expiration
        vm.startPrank(target);
        depositTimelock.withdraw(context, users.lender1, USDT, minWithdrawAmount, path);
        vm.stopPrank();

        // Verify withdrawal succeeded
        (,,,, uint256 depositedAmount,) =
            depositTimelock.depositInfo(depositTimelock.depositTokenId(users.lender1, target, context));
        assertEq(depositedAmount, 0, "Deposit should be withdrawn");
    }

    function test__Withdraw_WithUniswapV3_RevertWhen_AfterExpiration() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context-uniswap");
        uint256 depositAmount = 100_000 * 1e6; // 100k USDC (6 decimals)
        uint256 minWithdrawAmount = 100_000 * 1e6; // 100k USDT (6 decimals)
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit USDC
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDC, depositAmount, expiration);
        vm.stopPrank();

        // Warp past expiration
        vm.warp(expiration + 1);

        // Encode UniswapV3 path: USDT (output) - fee - USDC (input)
        bytes memory path = abi.encodePacked(USDT, uint24(100), USDC);

        // Try to withdraw after expiration (should fail)
        vm.startPrank(target);
        vm.expectRevert(IDepositTimelock.InvalidTimestamp.selector);
        depositTimelock.withdraw(context, users.lender1, USDT, minWithdrawAmount, path);
        vm.stopPrank();
    }

    function test__Withdraw_WithUniswapV3_RevertWhen_InvalidPath() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context-uniswap");
        uint256 depositAmount = 100_000 * 1e6; // 100k USDC (6 decimals)
        uint256 minWithdrawAmount = 98_000 * 1e6; // 98k USDT (6 decimals)
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit USDC
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDC, depositAmount, expiration);
        vm.stopPrank();

        // Encode wrong UniswapV3 path: USDT - USDC (missing fee)
        bytes memory wrongPath = abi.encodePacked(USDT, USDC);

        // Try to withdraw with invalid path (should fail)
        vm.startPrank(target);
        vm.expectRevert(); // Will revert with InvalidPathFormat or similar
        depositTimelock.withdraw(context, users.lender1, USDT, minWithdrawAmount, wrongPath);
        vm.stopPrank();
    }
}
