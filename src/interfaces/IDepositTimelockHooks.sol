// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title Deposit Timelock Callback Hooks
 * @author USD.AI Foundation
 */
interface IDepositTimelockHooks {
    /*------------------------------------------------------------------------*/
    /* Public API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Called when deposit is withdrawn
     * @param target Target address
     * @param context Context identifier
     * @param token Token address
     * @param depositAmount Deposit amount
     * @param withdrawAmount Withdraw amount
     * @param refundAmount Refund amount
     */
    function onDepositWithdrawn(
        address target,
        bytes32 context,
        address token,
        uint256 depositAmount,
        uint256 withdrawAmount,
        uint256 refundAmount
    ) external;
}
