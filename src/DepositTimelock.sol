// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import "./interfaces/IDepositTimelock.sol";
import "./interfaces/IDepositTimelockHooks.sol";

/**
 * @title Deposit Timelock
 * @author USD.AI Foundation
 */
contract DepositTimelock is
    IDepositTimelock,
    ERC165Upgradeable,
    ERC721Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;

    /*------------------------------------------------------------------------*/
    /* Constant */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Implementation version
     */
    string public constant IMPLEMENTATION_VERSION = "1.1";

    /**
     * @notice Deposits storage location
     * @dev keccak256(abi.encode(uint256(keccak256("depositTimelock.deposits")) - 1)) & ~bytes32(uint256(0xff));
     */
    bytes32 private constant DEPOSITS_STORAGE_LOCATION =
        0x7acdc53704e8fe7c86714ac2b064371f82f2d965ecacce8d646be33eba1fa900;

    /*------------------------------------------------------------------------*/
    /* Structures */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Deposit
     * @param depositor Depositor address
     * @param target Target address
     * @param context Context
     * @param token Token
     * @param amount Amount
     * @param expiration Expiration
     */
    struct Deposit {
        address depositor;
        address target;
        bytes32 context;
        address token;
        uint256 amount;
        uint64 expiration;
    }

    /**
     * @custom:storage-location erc7201:depositTimelock.deposits
     */
    struct Deposits {
        mapping(uint256 => Deposit) deposits;
    }

    /*------------------------------------------------------------------------*/
    /* Constructor */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Deposit Timelock Constructor
     */
    constructor() {
        _disableInitializers();
    }

    /*------------------------------------------------------------------------*/
    /* Initialization  */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Initialize the contract
     * @param admin Default admin address
     */
    function initialize(
        address admin
    ) external initializer {
        __ERC165_init();
        __ERC721_init("Deposit Timelock Receipt", "DT-RT");
        __AccessControl_init();

        /* Grant roles */
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /*------------------------------------------------------------------------*/
    /* Modifiers  */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Non-zero value modifier
     * @param value Value to check
     */
    modifier nonZeroUint(
        uint256 value
    ) {
        if (value == 0) revert InvalidAmount();
        _;
    }

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

    /**
     * @notice Non-zero bytes32 modifier
     * @param value Value to check
     */
    modifier nonZeroBytes32(
        bytes32 value
    ) {
        if (value == bytes32(0)) revert InvalidBytes32();
        _;
    }

    /*------------------------------------------------------------------------*/
    /* Storage getters */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Get reference to deposits storage
     *
     * @return $ Reference to deposits storage
     */
    function _getDepositsStorage() internal pure returns (Deposits storage $) {
        assembly {
            $.slot := DEPOSITS_STORAGE_LOCATION
        }
    }

    /*------------------------------------------------------------------------*/
    /* Internal helpers */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Helper function to compute deposit token ID
     * @param depositor Depositor address
     * @param target Target address
     * @param context Context
     * @return Deposit token ID
     */
    function _depositTokenId(
        address depositor,
        address target,
        bytes32 context
    ) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(depositor, target, context)));
    }

    /*------------------------------------------------------------------------*/
    /* Getters */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IDepositTimelock
     */
    function depositTokenId(
        address depositor,
        address target,
        bytes32 context
    ) external pure returns (uint256) {
        return _depositTokenId(depositor, target, context);
    }

    /**
     * @inheritdoc IDepositTimelock
     */
    function depositInfo(
        uint256 tokenId
    ) external view returns (address, address, bytes32, address, uint256, uint64) {
        /* Get deposit */
        Deposit memory deposit_ = _getDepositsStorage().deposits[tokenId];

        /* Return deposit information */
        return
            (
                deposit_.depositor,
                deposit_.target,
                deposit_.context,
                deposit_.token,
                deposit_.amount,
                deposit_.expiration
            );
    }

    /*------------------------------------------------------------------------*/
    /* Depositor API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IDepositTimelock
     */
    function deposit(
        address target,
        bytes32 context,
        address token,
        uint256 amount,
        uint64 expiration
    )
        external
        nonZeroAddress(target)
        nonZeroAddress(token)
        nonZeroUint(amount)
        nonZeroUint(expiration)
        nonZeroBytes32(context)
        nonReentrant
    {
        /* Compute token ID */
        uint256 tokenId = _depositTokenId(msg.sender, target, context);

        /* Validate deposit is not already set */
        if (_getDepositsStorage().deposits[tokenId].amount != 0) revert InvalidDeposit();

        /* Validate expiration is in the future */
        if (block.timestamp >= expiration) revert InvalidTimestamp();

        /* Transfer token from sender to this contract */
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        /* Set deposit */
        _getDepositsStorage().deposits[tokenId] = Deposit({
            depositor: msg.sender,
            target: target,
            context: context,
            token: token,
            amount: amount,
            expiration: expiration
        });

        /* Mint receipt token */
        _safeMint(msg.sender, tokenId);

        /* Emit deposit event */
        emit Deposited(msg.sender, target, context, token, amount, expiration);
    }

    /**
     * @inheritdoc IDepositTimelock
     */
    function cancel(
        address target,
        bytes32 context
    ) external nonZeroAddress(target) nonZeroBytes32(context) nonReentrant returns (uint256) {
        /* Compute token ID */
        uint256 tokenId = _depositTokenId(msg.sender, target, context);

        /* Get deposit */
        Deposit memory deposit_ = _getDepositsStorage().deposits[tokenId];

        /* Validate timelock has expired */
        if (block.timestamp <= deposit_.expiration) revert InvalidTimestamp();

        /* Validate deposit */
        if (deposit_.amount == 0) revert InvalidDeposit();

        /* Delete deposit */
        delete _getDepositsStorage().deposits[tokenId];

        /* Burn receipt token */
        _burn(tokenId);

        /* Transfer deposit amount from this contract to sender */
        IERC20(deposit_.token).safeTransfer(msg.sender, deposit_.amount);

        /* Emit cancel event */
        emit Canceled(msg.sender, target, context, deposit_.amount);

        /* Return deposit amount */
        return deposit_.amount;
    }

    /*------------------------------------------------------------------------*/
    /* Withdrawer API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IDepositTimelock
     */
    function withdraw(
        bytes32 context,
        address depositor,
        address token,
        uint256 amount
    ) external nonZeroBytes32(context) nonZeroAddress(depositor) nonZeroAddress(token) nonReentrant returns (uint256) {
        /* Compute token ID */
        uint256 tokenId = _depositTokenId(depositor, msg.sender, context);

        /* Get deposit */
        Deposit memory deposit_ = _getDepositsStorage().deposits[tokenId];

        /* Validate timelock hasn't expired */
        if (block.timestamp > deposit_.expiration) revert InvalidTimestamp();

        /* Validate deposit amount */
        if (deposit_.amount == 0) revert InvalidAmount();

        /* Validate withdraw token matches deposit token */
        if (token != deposit_.token) revert UnsupportedToken();

        /* Delete deposit */
        delete _getDepositsStorage().deposits[tokenId];

        /* Burn deposit receipt NFT */
        _burn(tokenId);

        /* Compute refund amount */
        uint256 refundAmount = deposit_.amount - amount;

        /* Transfer withdraw amount from this contract to sender */
        IERC20(token).safeTransfer(msg.sender, amount);

        /* Transfer refund to depositor */
        if (refundAmount > 0) IERC20(deposit_.token).safeTransfer(depositor, refundAmount);

        /* Call onDepositWithdrawn hook if depositor supports it */
        if (depositor.code.length != 0 && IERC165(depositor).supportsInterface(type(IDepositTimelockHooks).interfaceId))
        {
            IDepositTimelockHooks(depositor)
                .onDepositWithdrawn(
                    msg.sender, context, deposit_.token, deposit_.amount, amount, refundAmount
                );
        }

        /* Emit withdrawn event */
        emit Withdrawn(depositor, msg.sender, context, token, deposit_.amount, amount, refundAmount);

        return amount;
    }

    /*------------------------------------------------------------------------*/
    /* ERC721 Overrides */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IERC721
     */
    function approve(
        address,
        uint256
    ) public virtual override {
        revert("Transfers are disabled");
    }

    /**
     * @inheritdoc IERC721
     */
    function setApprovalForAll(
        address,
        bool
    ) public virtual override {
        revert("Transfers are disabled");
    }

    /**
     * @inheritdoc IERC721
     */
    function transferFrom(
        address,
        address,
        uint256
    ) public virtual override {
        revert("Transfers are disabled");
    }

    /**
     * @inheritdoc IERC721
     */
    function safeTransferFrom(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual override {
        revert("Transfers are disabled");
    }

    /*------------------------------------------------------------------------*/
    /* ERC165 */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(AccessControlUpgradeable, ERC721Upgradeable, ERC165Upgradeable) returns (bool) {
        return interfaceId == type(IDepositTimelock).interfaceId || super.supportsInterface(interfaceId);
    }
}
