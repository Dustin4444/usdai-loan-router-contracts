// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {BaseTest} from "../Base.t.sol";
import {IDepositTimelock} from "src/interfaces/IDepositTimelock.sol";

contract DepositTimelockAdminTest is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Test: addSwapAdapter */
    /*------------------------------------------------------------------------*/

    function test__AddSwapAdapter_Success() public {
        address newToken = makeAddr("newToken");
        address newSwapAdapter = makeAddr("newSwapAdapter");

        vm.startPrank(users.deployer);
        vm.expectEmit(true, true, true, true);
        emit IDepositTimelock.SwapAdapterAdded(newToken, newSwapAdapter);
        depositTimelock.addSwapAdapter(newToken, newSwapAdapter);
        vm.stopPrank();
    }

    function test__AddSwapAdapter_UpdateExisting() public {
        address token = USDAI;
        address newSwapAdapter = makeAddr("newSwapAdapter");

        vm.startPrank(users.deployer);

        // Update existing swap adapter
        depositTimelock.addSwapAdapter(token, newSwapAdapter);

        vm.stopPrank();
    }

    function test__AddSwapAdapter_RevertWhen_NotAdmin() public {
        address newToken = makeAddr("newToken");
        address newSwapAdapter = makeAddr("newSwapAdapter");

        vm.startPrank(users.borrower);
        vm.expectRevert();
        depositTimelock.addSwapAdapter(newToken, newSwapAdapter);
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: removeSwapAdapter */
    /*------------------------------------------------------------------------*/

    function test__RemoveSwapAdapter_Success() public {
        address token = USDAI;

        vm.startPrank(users.deployer);
        vm.expectEmit(true, true, true, true);
        emit IDepositTimelock.SwapAdapterRemoved(token);
        depositTimelock.removeSwapAdapter(token);
        vm.stopPrank();

        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;
        uint64 expiration = uint64(block.timestamp + 7 days);

        // Deposit
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, token, amount, expiration);
        vm.stopPrank();

        // Warp to middle of timelock (before expiration)
        vm.warp(block.timestamp + 3 days);

        // Try to withdraw to another token (should fail)
        vm.startPrank(target);
        vm.expectRevert(IDepositTimelock.UnsupportedToken.selector);
        depositTimelock.withdraw(context, users.lender1, USDC, amount, "");
        vm.stopPrank();
    }

    function test__RemoveSwapAdapter_NonExistent() public {
        address nonExistentToken = makeAddr("nonExistentToken");

        vm.startPrank(users.deployer);
        // Should not revert, just emit event
        depositTimelock.removeSwapAdapter(nonExistentToken);
        vm.stopPrank();
    }

    function test__RemoveSwapAdapter_RevertWhen_NotAdmin() public {
        address token = USDAI;

        vm.startPrank(users.borrower);
        vm.expectRevert();
        depositTimelock.removeSwapAdapter(token);
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: Access control */
    /*------------------------------------------------------------------------*/

    function test__AccessControl_DefaultAdmin() public view {
        bytes32 defaultAdminRole = 0x00; // DEFAULT_ADMIN_ROLE

        assertTrue(depositTimelock.hasRole(defaultAdminRole, users.deployer), "Deployer should have admin role");
        assertFalse(depositTimelock.hasRole(defaultAdminRole, users.borrower), "Borrower should not have admin role");
    }

    function test__AccessControl_GrantRole() public {
        bytes32 defaultAdminRole = 0x00;

        vm.startPrank(users.deployer);
        depositTimelock.grantRole(defaultAdminRole, users.admin);
        vm.stopPrank();

        assertTrue(depositTimelock.hasRole(defaultAdminRole, users.admin), "Admin should have admin role");
    }

    function test__AccessControl_RevokeRole() public {
        bytes32 defaultAdminRole = 0x00;

        // Grant role first
        vm.startPrank(users.deployer);
        depositTimelock.grantRole(defaultAdminRole, users.admin);
        assertTrue(depositTimelock.hasRole(defaultAdminRole, users.admin));

        // Revoke role
        depositTimelock.revokeRole(defaultAdminRole, users.admin);
        vm.stopPrank();

        assertFalse(depositTimelock.hasRole(defaultAdminRole, users.admin), "Admin role should be revoked");
    }
}
