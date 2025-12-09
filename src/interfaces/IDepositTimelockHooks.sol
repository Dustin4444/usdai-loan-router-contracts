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
     * @param target Target contract
     * @param context Context identifier
     * @param depositToken Deposit token address
     * @param withdrawToken Withdraw token address
     * @param depositAmount Deposit amount
     * @param withdrawAmount Withdraw amount
     * @param refundDepositAmount Refund deposit amount
     * @param refundWithdrawAmount Refund withdraw amount
     */
    function onDepositWithdrawn(
        address target,
        bytes32 context,
        address depositToken,
        address withdrawToken,
        uint256 depositAmount,
        uint256 withdrawAmount,
        uint256 refundDepositAmount,
        uint256 refundWithdrawAmount
    ) external;
}
