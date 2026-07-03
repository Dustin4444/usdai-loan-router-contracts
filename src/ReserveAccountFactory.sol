// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IReserveAccountFactory} from "./interfaces/IReserveAccountFactory.sol";
import {IReserveAccount} from "./interfaces/IReserveAccount.sol";

import {ReserveAccount} from "./ReserveAccount.sol";

/**
 * @title Reserve Account Factory
 * @author USD.AI Foundation
 */
contract ReserveAccountFactory is AccessControlUpgradeable, IReserveAccountFactory {
    using EnumerableSet for EnumerableSet.AddressSet;

    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Implementation version
     */
    string public constant IMPLEMENTATION_VERSION = "1.0";

    /**
     * @notice Reserve account manager role
     */
    bytes32 public constant RESERVE_ACCOUNT_MANAGER_ROLE = keccak256("RESERVE_ACCOUNT_MANAGER_ROLE");

    /**
     * @notice Borrower role on a reserve account
     */
    bytes32 internal constant BORROWER_ROLE = keccak256("BORROWER_ROLE");

    /*------------------------------------------------------------------------*/
    /* Immutable State */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Reserve account beacon
     */
    address private immutable _beacon;

    /*------------------------------------------------------------------------*/
    /* State */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Set of created reserve accounts
     */
    EnumerableSet.AddressSet private _reserveAccounts;

    /*------------------------------------------------------------------------*/
    /* Constructor */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Reserve Account Factory Constructor
     * @param beacon_ Beacon
     */
    constructor(
        address beacon_
    ) nonZeroAddress(beacon_) {
        /* Disable initialization of implementation contract */
        _disableInitializers();

        /* Set beacon */
        _beacon = beacon_;
    }

    /*------------------------------------------------------------------------*/
    /* Modifiers */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Non-zero address modifier
     * @param value Value to check
     */
    modifier nonZeroAddress(
        address value
    ) {
        if (value == address(0)) revert InvalidAddress();
        _;
    }

    /*------------------------------------------------------------------------*/
    /* Initializer */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Initialize the contract
     * @param admin Default admin address
     */
    function initialize(
        address admin
    ) external initializer nonZeroAddress(admin) {
        __AccessControl_init();

        /* Grant default admin role */
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /*------------------------------------------------------------------------*/
    /* Primary API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IReserveAccountFactory
     */
    function create(
        address borrower,
        address currencyToken,
        uint256 reservesRequired
    ) external onlyRole(RESERVE_ACCOUNT_MANAGER_ROLE) returns (address) {
        /* Deploy beacon proxy and initialize */
        address reserveAccount = address(
            new BeaconProxy(
                _beacon, abi.encodeCall(ReserveAccount.initialize, (borrower, currencyToken, reservesRequired))
            )
        );

        /* Add to registry */
        _reserveAccounts.add(reserveAccount);

        /* Emit ReserveAccountCreated event */
        emit ReserveAccountCreated(reserveAccount, borrower);

        return reserveAccount;
    }

    /**
     * @inheritdoc IReserveAccountFactory
     */
    function register(
        address reserveAccount,
        address borrower
    ) external onlyRole(RESERVE_ACCOUNT_MANAGER_ROLE) {
        /* Check that the reserve account isn't enumerated already */
        if (isReserveAccount(reserveAccount)) revert AlreadyRegistered();

        /* Validate reserve account supports IReserveAccount interface */
        if (
            reserveAccount.code.length == 0
                || !IERC165(reserveAccount).supportsInterface(type(IReserveAccount).interfaceId)
        ) {
            revert InvalidReserveAccount();
        }

        /* Verify that the borrower has BORROWER_ROLE role */
        if (!IAccessControl(reserveAccount).hasRole(BORROWER_ROLE, borrower)) revert InvalidBorrower();

        /* Add to registry */
        _reserveAccounts.add(reserveAccount);

        /* Emit ReserveAccountCreated event */
        emit ReserveAccountCreated(reserveAccount, borrower);
    }

    /*------------------------------------------------------------------------*/
    /* Getters */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IReserveAccountFactory
     */
    function beacon() external view returns (address) {
        return _beacon;
    }

    /**
     * @inheritdoc IReserveAccountFactory
     */
    function isReserveAccount(
        address reserveAccount
    ) public view returns (bool) {
        return _reserveAccounts.contains(reserveAccount);
    }

    /**
     * @inheritdoc IReserveAccountFactory
     */
    function getReserveAccounts(
        uint256 offset,
        uint256 count
    ) external view returns (address[] memory) {
        /* Get total number of reserve accounts */
        uint256 total = _reserveAccounts.length();

        /* Return empty array when offset is past the end */
        if (offset >= total) return new address[](0);

        /* Clamp count to the remaining accounts */
        uint256 remaining = total - offset;

        /* Size the array to the smaller of count and remaining */
        uint256 size = count < remaining ? count : remaining;

        /* Allocate the array */
        address[] memory accounts = new address[](size);

        /* Fill the array from the requested offset */
        for (uint256 i = 0; i < size; i++) {
            accounts[i] = _reserveAccounts.at(offset + i);
        }

        return accounts;
    }

    /**
     * @inheritdoc IReserveAccountFactory
     */
    function getReserveAccountCount() external view returns (uint256) {
        return _reserveAccounts.length();
    }

    /**
     * @inheritdoc IReserveAccountFactory
     */
    function getReserveAccountAt(
        uint256 index
    ) external view returns (address) {
        return _reserveAccounts.at(index);
    }

    /*------------------------------------------------------------------------*/
    /* ERC165 */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return interfaceId == type(IReserveAccountFactory).interfaceId || super.supportsInterface(interfaceId);
    }
}
