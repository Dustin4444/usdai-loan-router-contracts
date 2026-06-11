// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import "./interfaces/ICollateralTimelock.sol";

/**
 * @title Collateral Timelock
 * @author USD.AI Foundation
 */
contract CollateralTimelock is
    ICollateralTimelock,
    ERC165Upgradeable,
    ERC721Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardTransient
{
    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Implementation version
     */
    string public constant IMPLEMENTATION_VERSION = "1.0";

    /**
     * @notice Deposits storage location
     * @dev keccak256(abi.encode(uint256(keccak256("collateralTimelock.deposits")) - 1)) & ~bytes32(uint256(0xff));
     */
    bytes32 private constant DEPOSITS_STORAGE_LOCATION =
        0xdaddcca2e75d26ae66fbeaaafa630b7784525a6d6f5c7492734eabbb160c6b00;

    /**
     * @notice Depositor role
     */
    bytes32 internal constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    /*------------------------------------------------------------------------*/
    /* Structures */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Deposit
     * @param depositor Depositor address
     * @param target Target address
     * @param context Context identifier
     * @param token Token address
     * @param tokenIds Token IDs
     * @param expiration Expiration timestamp
     */
    struct Deposit {
        address depositor;
        address target;
        bytes32 context;
        address token;
        uint256[] tokenIds;
        uint64 expiration;
    }

    /**
     * @custom:storage-location erc7201:collateralTimelock.deposits
     */
    struct Deposits {
        mapping(uint256 => Deposit) deposits;
    }

    /*------------------------------------------------------------------------*/
    /* Constructor */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Collateral Timelock Constructor
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
        __ERC721_init("Collateral Timelock Receipt", "CT-RT");
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
     * @param target Target address
     * @param context Context identifier
     * @param token Token address
     * @param tokenIds Token IDs
     * @return Deposit token ID
     */
    function _depositTokenId(
        address target,
        bytes32 context,
        address token,
        uint256[] calldata tokenIds
    ) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(target, context, token, tokenIds)));
    }

    /*------------------------------------------------------------------------*/
    /* Getters */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ICollateralTimelock
     */
    function depositTokenId(
        address target,
        bytes32 context,
        address token,
        uint256[] calldata tokenIds
    ) external pure returns (uint256) {
        return _depositTokenId(target, context, token, tokenIds);
    }

    /**
     * @inheritdoc ICollateralTimelock
     */
    function depositInfo(
        uint256 tokenId
    ) external view returns (address, address, bytes32, address, uint256[] memory, uint64) {
        /* Get deposit */
        Deposit memory deposit_ = _getDepositsStorage().deposits[tokenId];

        /* Return deposit information */
        return
            (
                deposit_.depositor,
                deposit_.target,
                deposit_.context,
                deposit_.token,
                deposit_.tokenIds,
                deposit_.expiration
            );
    }

    /*------------------------------------------------------------------------*/
    /* Depositor API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ICollateralTimelock
     */
    function deposit(
        address target,
        bytes32 context,
        address token,
        uint256[] calldata tokenIds,
        uint64 expiration
    )
        external
        onlyRole(DEPOSITOR_ROLE)
        nonZeroAddress(target)
        nonZeroBytes32(context)
        nonZeroAddress(token)
        nonZeroUint(tokenIds.length)
        nonZeroUint(expiration)
        nonReentrant
    {
        /* Compute token ID */
        uint256 tokenId = _depositTokenId(target, context, token, tokenIds);

        /* Validate deposit does not exist */
        if (_getDepositsStorage().deposits[tokenId].depositor != address(0)) revert InvalidDeposit();

        /* Validate expiration is in the future */
        if (block.timestamp >= expiration) revert InvalidTimestamp();

        /* Create deposit */
        _getDepositsStorage().deposits[tokenId] = Deposit({
            depositor: msg.sender,
            target: target,
            context: context,
            token: token,
            tokenIds: tokenIds,
            expiration: expiration
        });

        /* Mint receipt token */
        _safeMint(msg.sender, tokenId);

        /* Transfer each token from caller to this contract */
        for (uint256 i; i < tokenIds.length; i++) {
            IERC721(token).transferFrom(msg.sender, address(this), tokenIds[i]);
        }

        /* Emit Deposited event */
        emit Deposited(msg.sender, target, context, token, tokenIds, expiration);
    }

    /**
     * @inheritdoc ICollateralTimelock
     */
    function cancel(
        address target,
        bytes32 context,
        address token,
        uint256[] calldata tokenIds
    ) external nonZeroAddress(target) nonZeroBytes32(context) nonZeroAddress(token) nonReentrant {
        /* Compute token ID */
        uint256 tokenId = _depositTokenId(target, context, token, tokenIds);

        /* Get deposit */
        Deposit memory deposit_ = _getDepositsStorage().deposits[tokenId];

        /* Validate deposit exists */
        if (deposit_.depositor == address(0)) revert InvalidDeposit();

        /* Validate caller is the depositor */
        if (deposit_.depositor != msg.sender) revert InvalidCaller();

        /* Validate timelock has expired */
        if (block.timestamp <= deposit_.expiration) revert InvalidTimestamp();

        /* Delete deposit */
        delete _getDepositsStorage().deposits[tokenId];

        /* Burn receipt token */
        _burn(tokenId);

        /* Transfer each token back to depositor */
        for (uint256 i; i < deposit_.tokenIds.length; i++) {
            IERC721(deposit_.token).safeTransferFrom(address(this), msg.sender, deposit_.tokenIds[i]);
        }

        /* Emit Canceled event */
        emit Canceled(msg.sender, target, context, token, deposit_.tokenIds);
    }

    /*------------------------------------------------------------------------*/
    /* Withdrawer API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ICollateralTimelock
     */
    function withdraw(
        bytes32 context,
        address token,
        uint256[] calldata tokenIds
    ) external nonZeroBytes32(context) nonZeroAddress(token) nonReentrant {
        /* Compute token ID */
        uint256 tokenId = _depositTokenId(msg.sender, context, token, tokenIds);

        /* Get deposit */
        Deposit memory deposit_ = _getDepositsStorage().deposits[tokenId];

        /* Validate deposit exists */
        if (deposit_.depositor == address(0)) revert InvalidDeposit();

        /* Validate timelock hasn't expired */
        if (block.timestamp >= deposit_.expiration) revert InvalidTimestamp();

        /* Delete deposit */
        delete _getDepositsStorage().deposits[tokenId];

        /* Burn receipt token */
        _burn(tokenId);

        /* Transfer each token to caller */
        for (uint256 i; i < tokenIds.length; i++) {
            IERC721(token).safeTransferFrom(address(this), msg.sender, tokenIds[i]);
        }

        /* Emit Withdrawn event */
        emit Withdrawn(deposit_.depositor, msg.sender, context, token, tokenIds);
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
        return interfaceId == type(ICollateralTimelock).interfaceId || super.supportsInterface(interfaceId);
    }
}
