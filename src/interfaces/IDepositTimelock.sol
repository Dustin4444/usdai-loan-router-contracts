// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title Deposit Timelock Interface
 * @author USD.AI Foundation
 */
interface IDepositTimelock {
    /*------------------------------------------------------------------------*/
    /* Errors */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Invalid amount
     */
    error InvalidAmount();

    /**
     * @notice Invalid address
     */
    error InvalidAddress();

    /**
     * @notice Invalid bytes32
     */
    error InvalidBytes32();

    /**
     * @notice Invalid deposit
     */
    error InvalidDeposit();

    /**
     * @notice Invalid timestamp
     */
    error InvalidTimestamp();

    /**
     * @notice Unsupported token
     */
    error UnsupportedToken();

    /*------------------------------------------------------------------------*/
    /* Events */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Emitted when a deposit is made
     * @param depositor Depositor address
     * @param target Target contract that can withdraw
     * @param context Context identifier
     * @param token Token address
     * @param amount Amount deposited
     * @param expiration Expiration timestamp
     */
    event Deposited(
        address indexed depositor,
        address indexed target,
        bytes32 indexed context,
        address token,
        uint256 amount,
        uint64 expiration
    );

    /**
     * @notice Emitted when a deposit is canceled
     * @param depositor Depositor address
     * @param target Target contract
     * @param context Context identifier
     * @param token Token address
     * @param amount Amount returned
     */
    event Canceled(
        address indexed depositor, address indexed target, bytes32 indexed context, address token, uint256 amount
    );

    /**
     * @notice Emitted when a deposit is withdrawn
     * @param depositor Depositor address
     * @param target Target address
     * @param context Context identifier
     * @param token Token address
     * @param depositAmount Deposit amount
     * @param withdrawAmount Withdraw amount
     * @param refundAmount Deposit amount refunded
     */
    event Withdrawn(
        address indexed depositor,
        address indexed target,
        bytes32 indexed context,
        address token,
        uint256 depositAmount,
        uint256 withdrawAmount,
        uint256 refundAmount
    );

    /*------------------------------------------------------------------------*/
    /* Getters */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Get deposit token ID
     * @param depositor Depositor address
     * @param target Target address
     * @param context Context
     * @return Deposit token ID
     */
    function depositTokenId(
        address depositor,
        address target,
        bytes32 context
    ) external pure returns (uint256);

    /**
     * @notice Get deposit information
     * @param tokenId Token ID
     * @return depositor Depositor address
     * @return target Target contract address
     * @return context Context identifier
     * @return token Token address
     * @return amount Amount deposited
     * @return expiration Expiration timestamp
     */
    function depositInfo(
        uint256 tokenId
    )
        external
        view
        returns (address depositor, address target, bytes32 context, address token, uint256 amount, uint64 expiration);

    /*------------------------------------------------------------------------*/
    /* Depositor API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Deposit tokens with timelock
     * @param target Target contract that can withdraw
     * @param context Context identifier
     * @param token Token address
     * @param amount Amount to deposit
     * @param expiration Expiration timestamp
     */
    function deposit(
        address target,
        bytes32 context,
        address token,
        uint256 amount,
        uint64 expiration
    ) external;

    /**
     * @notice Cancel deposit after expiration
     * @param target Target contract
     * @param context Context identifier
     * @return Amount returned
     */
    function cancel(
        address target,
        bytes32 context
    ) external returns (uint256);

    /*------------------------------------------------------------------------*/
    /* Withdrawer API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Withdraw deposit before expiration
     * @param depositor Depositor address
     * @param context Context identifier
     * @param token Token address
     * @param amount Amount to withdraw
     * @return Withdraw amount
     */
    function withdraw(
        address depositor,
        bytes32 context,
        address token,
        uint256 amount
    ) external returns (uint256);
}
