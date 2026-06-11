// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title Collateral Timelock Interface
 * @author USD.AI Foundation
 */
interface ICollateralTimelock {
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
     * @notice Invalid caller
     */
    error InvalidCaller();

    /*------------------------------------------------------------------------*/
    /* Events */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Emitted when a deposit is made
     * @param depositor Depositor address
     * @param target Target address
     * @param context Context identifier
     * @param token Token address
     * @param tokenIds Token IDs
     * @param expiration Expiration timestamp
     */
    event Deposited(
        address indexed depositor,
        address indexed target,
        bytes32 indexed context,
        address token,
        uint256[] tokenIds,
        uint64 expiration
    );

    /**
     * @notice Emitted when a deposit is canceled
     * @param depositor Depositor address
     * @param target Target address
     * @param context Context identifier
     * @param token Token address
     * @param tokenIds Token IDs
     */
    event Canceled(
        address indexed depositor, address indexed target, bytes32 indexed context, address token, uint256[] tokenIds
    );

    /**
     * @notice Emitted when a deposit is withdrawn
     * @param depositor Depositor address
     * @param target Target address
     * @param context Context identifier
     * @param token Token address
     * @param tokenIds Token IDs
     */
    event Withdrawn(
        address indexed depositor, address indexed target, bytes32 indexed context, address token, uint256[] tokenIds
    );

    /*------------------------------------------------------------------------*/
    /* Getters */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Get deposit token ID
     * @param target Target address
     * @param context Context identifier
     * @param token Token address
     * @param tokenIds Token IDs
     * @return Deposit token ID
     */
    function depositTokenId(
        address target,
        bytes32 context,
        address token,
        uint256[] calldata tokenIds
    ) external pure returns (uint256);

    /**
     * @notice Get deposit information
     * @param tokenId Token ID
     * @return depositor Depositor address
     * @return target Target address
     * @return context Context identifier
     * @return token Token address
     * @return tokenIds Token IDs
     * @return expiration Expiration timestamp
     */
    function depositInfo(
        uint256 tokenId
    )
        external
        view
        returns (
            address depositor,
            address target,
            bytes32 context,
            address token,
            uint256[] memory tokenIds,
            uint64 expiration
        );

    /*------------------------------------------------------------------------*/
    /* Depositor API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Deposit tokens with timelock
     * @param target Target address
     * @param context Context identifier
     * @param token Token address
     * @param tokenIds Token IDs
     * @param expiration Expiration timestamp
     */
    function deposit(
        address target,
        bytes32 context,
        address token,
        uint256[] calldata tokenIds,
        uint64 expiration
    ) external;

    /**
     * @notice Cancel deposit after expiration
     * @param target Target address
     * @param context Context identifier
     * @param token Token address
     * @param tokenIds Token IDs
     */
    function cancel(
        address target,
        bytes32 context,
        address token,
        uint256[] calldata tokenIds
    ) external;

    /*------------------------------------------------------------------------*/
    /* Withdrawer API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Withdraw deposit before expiration
     * @param context Context identifier
     * @param token Token address
     * @param tokenIds Token IDs
     */
    function withdraw(
        bytes32 context,
        address token,
        uint256[] calldata tokenIds
    ) external;
}
