// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ILoanRouterV2.sol";

/**
 * @title Reserve Account Interface
 * @author USD.AI Foundation
 */
interface IReserveAccount {
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
     * @notice Insufficient reserves balance
     */
    error InsufficientReserves();

    /**
     * @notice Invalid currency token
     */
    error InvalidCurrencyToken();

    /*------------------------------------------------------------------------*/
    /* Events */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Emitted when funds are forwarded for repayment
     * @param amount Amount forwarded
     */
    event RepaymentForwarded(uint256 amount);

    /**
     * @notice Emitted when excess reserves are withdrawn
     * @param recipient Recipient address
     * @param amount Amount withdrawn
     */
    event ReservesWithdrawn(address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when reserves required are updated
     * @param required New reserves required
     */
    event ReservesRequiredSet(uint256 required);

    /**
     * @notice Emitted when admin executes an arbitrary call
     * @param target Target address
     * @param selector Selector of call
     */
    event Executed(address indexed target, bytes4 indexed selector);

    /*------------------------------------------------------------------------*/
    /* Getters */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Get admin address
     * @return Admin address
     */
    function admin() external view returns (address);

    /**
     * @notice Get loan router address
     * @return Loan router address
     */
    function loanRouter() external view returns (address);

    /**
     * @notice Get currency token address
     * @return Currency token address
     */
    function currencyToken() external view returns (address);

    /**
     * @notice Get reserves state
     * @return required Reserves required
     * @return excess Excess balance
     */
    function reserves() external view returns (uint256 required, uint256 excess);

    /*------------------------------------------------------------------------*/
    /* Public API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Repay a loan
     * @param loanTerms Loan terms
     * @param amount Repayment amount
     */
    function repay(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        uint256 amount
    ) external;

    /**
     * @notice Withdraw funds (excess of reserves)
     * @param recipient Recipient
     * @param amount Withdraw amount
     */
    function withdraw(
        address recipient,
        uint256 amount
    ) external;

    /*------------------------------------------------------------------------*/
    /* Permissioned API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Execute an arbitrary call
     * @param target Target address
     * @param data Call data
     * @return result Result of the call
     */
    function execute(
        address target,
        bytes calldata data
    ) external returns (bytes memory);

    /**
     * @notice Set reserves required
     * @param required Reserves required
     */
    function setReservesRequired(
        uint256 required
    ) external;
}
