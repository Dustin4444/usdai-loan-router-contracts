// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.29;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import "./interfaces/IDepositTimelock.sol";
import "./interfaces/IDepositTimelockHooks.sol";
import "./interfaces/ISwapAdapter.sol";

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
    string public constant IMPLEMENTATION_VERSION = "1.0";

    /**
     * @notice Deposits storage location
     * @dev keccak256(abi.encode(uint256(keccak256("depositTimelock.deposits")) - 1)) & ~bytes32(uint256(0xff));
     */
    bytes32 private constant DEPOSITS_STORAGE_LOCATION =
        0x7acdc53704e8fe7c86714ac2b064371f82f2d965ecacce8d646be33eba1fa900;

    /**
     * @notice Swap adapters storage location
     * @dev keccak256(abi.encode(uint256(keccak256("depositTimelock.swapAdapters")) - 1)) & ~bytes32(uint256(0xff));
     */
    bytes32 private constant SWAP_ADAPTERS_STORAGE_LOCATION =
        0x98353fb5c3c1dd6abbdcf93cc47d2fc2ecdba2d347d96492a524153dda798100;

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

    /**
     * @custom:storage-location erc7201:depositTimelock.swapAdapters
     */
    struct SwapAdapters {
        mapping(address => address) swapAdapters;
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

    /**
     * @notice Get reference to swap adapters storage
     *
     * @return $ Reference to swap adapters storage
     */
    function _getSwapAdaptersStorage() internal pure returns (SwapAdapters storage $) {
        assembly {
            $.slot := SWAP_ADAPTERS_STORAGE_LOCATION
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

    /**
     * @notice Swap
     * @param depositToken Deposit token
     * @param withdrawToken Withdraw token
     * @param depositAmount Deposit amount
     * @param swapData Swap data
     * @param amount Minimum withdraw amount
     * @return Output amount
     * @return Refund deposit amount
     * @return Refund output amount
     */
    function _swap(
        address depositToken,
        address withdrawToken,
        uint256 depositAmount,
        bytes memory swapData,
        uint256 amount
    ) internal returns (uint256, uint256, uint256) {
        /* If deposit token is withdraw token, return the deposit amount and
         * refund withdraw amount */
        if (depositToken == address(withdrawToken)) {
            return (amount, 0, depositAmount - amount);
        }

        /* Get swap adapter */
        address swapAdapter = _getSwapAdaptersStorage().swapAdapters[depositToken];

        /* Validate swap adapter exists */
        if (swapAdapter == address(0)) revert UnsupportedToken();

        /* Approve the swap adapter to spend the token in */
        IERC20(depositToken).forceApprove(swapAdapter, depositAmount);

        /* Swap using exact output */
        (uint256 withdrawAmount, uint256 refundDepositAmount, uint256 refundWithdrawAmount) =
            ISwapAdapter(swapAdapter).swap(depositToken, withdrawToken, depositAmount, amount, swapData);

        /* Unset approval for the swap adapter to spend the token in */
        IERC20(depositToken).forceApprove(address(swapAdapter), 0);

        /* Validate amounts */
        if (withdrawAmount < amount || withdrawAmount == 0) revert InvalidAmount();

        return (withdrawAmount, refundDepositAmount, refundWithdrawAmount);
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
        address withdrawToken,
        uint256 amount,
        bytes calldata swapData
    )
        external
        nonZeroBytes32(context)
        nonZeroAddress(depositor)
        nonZeroAddress(withdrawToken)
        nonReentrant
        returns (uint256)
    {
        /* Compute token ID */
        uint256 tokenId = _depositTokenId(depositor, msg.sender, context);

        /* Get deposit */
        Deposit memory deposit_ = _getDepositsStorage().deposits[tokenId];

        /* Validate timelock hasn't expired */
        if (block.timestamp > deposit_.expiration) revert InvalidTimestamp();

        /* Validate deposit amount */
        if (deposit_.amount == 0) revert InvalidAmount();

        /* Delete deposit */
        delete _getDepositsStorage().deposits[tokenId];

        /* Burn deposit receipt NFT */
        _burn(tokenId);

        /* Swap */
        (uint256 withdrawAmount, uint256 refundDepositAmount, uint256 refundWithdrawAmount) =
            _swap(deposit_.token, withdrawToken, deposit_.amount, swapData, amount);

        /* Transfer withdraw amount from this contract to sender */
        IERC20(withdrawToken).safeTransfer(msg.sender, withdrawAmount);

        /* Transfer refund deposit amount from this contract to depositor */
        if (refundDepositAmount > 0) IERC20(deposit_.token).safeTransfer(depositor, refundDepositAmount);

        /* Transfer refund output amount from this contract to sender */
        if (refundWithdrawAmount > 0) IERC20(withdrawToken).safeTransfer(depositor, refundWithdrawAmount);

        /* Call onDepositWithdrawn hook if depositor is a contract and implements IDepositTimelockHooks
        interface */
        if (depositor.code.length != 0 && IERC165(depositor).supportsInterface(type(IDepositTimelockHooks).interfaceId))
        {
            IDepositTimelockHooks(depositor)
                .onDepositWithdrawn(
                    msg.sender,
                    context,
                    deposit_.token,
                    withdrawToken,
                    deposit_.amount,
                    withdrawAmount,
                    refundDepositAmount,
                    refundWithdrawAmount
                );
        }

        /* Emit withdrawn event */
        emit Withdrawn(
            depositor,
            msg.sender,
            context,
            deposit_.token,
            withdrawToken,
            deposit_.amount,
            withdrawAmount,
            refundDepositAmount,
            refundWithdrawAmount
        );

        return withdrawAmount;
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
    /* Permissioned API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IDepositTimelock
     */
    function addSwapAdapter(
        address token,
        address swapAdapter
    ) external nonZeroAddress(token) nonZeroAddress(swapAdapter) onlyRole(DEFAULT_ADMIN_ROLE) {
        /* Set swap adapter */
        _getSwapAdaptersStorage().swapAdapters[token] = swapAdapter;

        /* Emit swap adapter added event */
        emit SwapAdapterAdded(token, swapAdapter);
    }

    /**
     * @inheritdoc IDepositTimelock
     */
    function removeSwapAdapter(
        address token
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        delete _getSwapAdaptersStorage().swapAdapters[token];

        /* Emit swap adapter removed event */
        emit SwapAdapterRemoved(token);
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
