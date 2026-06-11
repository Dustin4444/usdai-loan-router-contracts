// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {BaseTest} from "../Base.t.sol";
import {IDepositTimelock} from "src/interfaces/IDepositTimelock.sol";

contract DepositTimelockAdminTest is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Test: withdraw */
    /*------------------------------------------------------------------------*/

    function test__Withdraw_RevertWhen_WrongToken() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;
        uint64 expiration = uint64(block.timestamp + 7 days);

        /* Make a valid deposit */
        vm.startPrank(users.lender1);
        depositTimelock.deposit(target, context, USDAI, amount, expiration);
        vm.stopPrank();

        /* Warp to middle of timelock */
        vm.warp(block.timestamp + 3 days);

        /* Withdraw with non-deposit token should fail */
        vm.startPrank(target);
        vm.expectRevert(IDepositTimelock.UnsupportedToken.selector);
        depositTimelock.withdraw(users.lender1, context, USDC, amount);
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

        /* Grant role first */
        vm.startPrank(users.deployer);
        depositTimelock.grantRole(defaultAdminRole, users.admin);
        assertTrue(depositTimelock.hasRole(defaultAdminRole, users.admin));

        /* Revoke role */
        depositTimelock.revokeRole(defaultAdminRole, users.admin);
        vm.stopPrank();

        assertFalse(depositTimelock.hasRole(defaultAdminRole, users.admin), "Admin role should be revoked");
    }
}
