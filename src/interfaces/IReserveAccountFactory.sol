// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title Reserve Account Factory Interface
 * @author USD.AI Foundation
 */
interface IReserveAccountFactory {
    /*------------------------------------------------------------------------*/
    /* Errors */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Invalid address
     */
    error InvalidAddress();

    /*------------------------------------------------------------------------*/
    /* Events */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Emitted when a reserve account is created
     * @param reserveAccount Reserve account address
     */
    event ReserveAccountCreated(address indexed reserveAccount);

    /*------------------------------------------------------------------------*/
    /* Primary API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Create a reserve account beacon proxy
     * @param borrower Borrower address
     * @param currencyToken Currency token
     * @param reservesRequired Initial reserves required
     * @return Reserve account address
     */
    function create(
        address borrower,
        address currencyToken,
        uint256 reservesRequired
    ) external returns (address);

    /*------------------------------------------------------------------------*/
    /* Getters */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Get the beacon
     * @return Beacon address
     */
    function beacon() external view returns (address);

    /**
     * @notice Check whether an address is a reserve account from this factory
     * @param reserveAccount Reserve account address
     * @return True if created by this factory
     */
    function isReserveAccount(
        address reserveAccount
    ) external view returns (bool);

    /**
     * @notice Get reserve accounts
     * @param offset Index to start from
     * @param count Maximum number of accounts to return
     * @return Reserve account addresses
     */
    function getReserveAccounts(
        uint256 offset,
        uint256 count
    ) external view returns (address[] memory);

    /**
     * @notice Get reserve account count
     * @return Number of reserve accounts
     */
    function getReserveAccountCount() external view returns (uint256);

    /**
     * @notice Get reserve account at index
     * @param index Index
     * @return Reserve account address
     */
    function getReserveAccountAt(
        uint256 index
    ) external view returns (address);
}
