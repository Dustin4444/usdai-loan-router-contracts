// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.29;

import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import "../interfaces/external/ICollateralLiquidationReceiver.sol";
import "../interfaces/external/ICollateralLiquidator.sol";

/**
 * @title External Collateral Liquidator
 * @author USD.AI Foundation
 */
contract ExternalCollateralLiquidator is
    AccessControlUpgradeable,
    MulticallUpgradeable,
    ICollateralLiquidator,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;

    /*------------------------------------------------------------------------*/
    /* Access Control Roles */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Collateral liquidator role
     */
    bytes32 public constant COLLATERAL_LIQUIDATOR_ROLE = keccak256("COLLATERAL_LIQUIDATOR");

    /**
     * @notice Collateral tracker storage location
     * @dev keccak256(abi.encode(uint256(keccak256("externalCollateralLiquidator.collateralTracker")) - 1)) &
     * ~bytes32(uint256(0xff));
     */
    bytes32 private constant COLLATERAL_TRACKER_STORAGE_LOCATION =
        0xc6fb0d6c7350db14142798001ac262c683860b2370a687ebf465f7c51f14f200;

    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Implementation version
     */
    string public constant IMPLEMENTATION_VERSION = "1.0";

    /*------------------------------------------------------------------------*/
    /* Errors */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Invalid token
     */
    error InvalidToken();

    /**
     * @notice Invalid liquidation
     */
    error InvalidLiquidation();

    /**
     * @notice Invalid collateral state
     */
    error InvalidCollateralState();

    /*------------------------------------------------------------------------*/
    /* Events */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Emitted when collateral is received
     * @param collateralHash Collateral hash
     * @param source Source that provided collateral
     * @param collateralToken Collateral token contract
     * @param collateralTokenId Collateral token ID
     */
    event CollateralReceived(
        bytes32 indexed collateralHash, address indexed source, address collateralToken, uint256 collateralTokenId
    );

    /**
     * @notice Emitted when collateral is withdrawn
     * @param collateralHash Collateral hash
     * @param source Source that provided collateral
     * @param collateralToken Collateral token contract
     * @param collateralTokenId Collateral token ID
     */
    event CollateralWithdrawn(
        bytes32 indexed collateralHash, address indexed source, address collateralToken, uint256 collateralTokenId
    );

    /**
     * @notice Emitted when collateral is liquidated
     * @param collateralHash Collateral hash
     * @param collateralToken Collateral token contract
     * @param collateralTokenId Collateral token ID
     * @param proceeds Proceeds in currency tokens
     */
    event CollateralLiquidated(
        bytes32 indexed collateralHash, address collateralToken, uint256 collateralTokenId, uint256 proceeds
    );

    /*------------------------------------------------------------------------*/
    /* Structures */
    /*------------------------------------------------------------------------*/

    /**
     * @custom:storage-location erc7201:externalCollateralLiquidator.collateralTracker
     */
    struct CollateralTracker {
        mapping(bytes32 => CollateralStatus) collateralTracker;
    }

    /*------------------------------------------------------------------------*/
    /* Enums */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Collateral Status
     */
    enum CollateralStatus {
        Absent,
        Present,
        Withdrawn
    }

    /*------------------------------------------------------------------------*/
    /* Constructor */
    /*------------------------------------------------------------------------*/

    /**
     * @notice ExternalCollateralLiquidator constructor
     */
    constructor() {
        _disableInitializers();
    }

    /*------------------------------------------------------------------------*/
    /* Initializer */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Initializer
     */
    function initialize(
        address admin
    ) external initializer {
        __Multicall_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /*------------------------------------------------------------------------*/
    /* Helper Functions */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Get reference to collateral tracker storage
     * @return $ Reference to collateral tracker storage
     */
    function _getCollateralTrackerStorage() private pure returns (CollateralTracker storage $) {
        assembly {
            $.slot := COLLATERAL_TRACKER_STORAGE_LOCATION
        }
    }

    /**
     * @notice Helper function to compute collateral hash
     * @param source Source that provided collateral
     * @param collateralToken Collateral token
     * @param collateralTokenId Collateral token ID
     * @param currencyToken Currency token
     * @param collateralWrapperContext Collateral wrapper context
     * @param liquidationContext Liquidation callback context
     */
    function _collateralHash(
        address source,
        address collateralToken,
        uint256 collateralTokenId,
        address currencyToken,
        bytes calldata collateralWrapperContext,
        bytes calldata liquidationContext
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                block.chainid,
                source,
                collateralToken,
                collateralTokenId,
                collateralWrapperContext,
                currencyToken,
                liquidationContext
            )
        );
    }

    /*------------------------------------------------------------------------*/
    /* Getters */
    /*------------------------------------------------------------------------*/
    /**
     * Get collateral status
     * @param collateralHash Collateral hash
     * @return Collateral tracker
     */
    function collateralStatus(
        bytes32 collateralHash
    ) external view returns (CollateralStatus) {
        return _getCollateralTrackerStorage().collateralTracker[collateralHash];
    }

    /*------------------------------------------------------------------------*/
    /* Implementation */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ICollateralLiquidator
     */
    function name() external pure returns (string memory) {
        return "ExternalCollateralLiquidator";
    }

    /**
     * @inheritdoc ICollateralLiquidator
     */
    function liquidate(
        address currencyToken,
        address collateralToken,
        uint256 collateralTokenId,
        bytes calldata collateralWrapperContext,
        bytes calldata liquidationContext
    ) external nonReentrant {
        /* Check collateralToken and currencyToken is not zero address */
        if (collateralToken == address(0) || currencyToken == address(0)) revert InvalidToken();

        /* Compute liquidation hash */
        bytes32 collateralHash = _collateralHash(
            msg.sender, collateralToken, collateralTokenId, currencyToken, collateralWrapperContext, liquidationContext
        );

        /* Validate collateral is not already present */
        if (_getCollateralTrackerStorage().collateralTracker[collateralHash] != CollateralStatus.Absent) {
            revert InvalidLiquidation();
        }

        /* Transfer collateral token from source to this contract */
        IERC721(collateralToken).transferFrom(msg.sender, address(this), collateralTokenId);

        /* Update collateral tracker */
        _getCollateralTrackerStorage().collateralTracker[collateralHash] = CollateralStatus.Present;

        /* Emit CollateralReceived */
        emit CollateralReceived(collateralHash, msg.sender, collateralToken, collateralTokenId);
    }

    /**
     * @notice Withdraw collateral
     *
     * Emits a {CollateralWithdrawn} event.
     *
     * @param source Source that provided collateral
     * @param currencyToken Currency token
     * @param collateralToken Collateral token, either underlying token or collateral wrapper
     * @param collateralTokenId Collateral token ID
     * @param collateralWrapperContext Collateral wrapper context
     * @param liquidationContext Liquidation callback context
     */
    function withdrawCollateral(
        address source,
        address currencyToken,
        address collateralToken,
        uint256 collateralTokenId,
        bytes calldata collateralWrapperContext,
        bytes calldata liquidationContext
    ) external nonReentrant onlyRole(COLLATERAL_LIQUIDATOR_ROLE) {
        /* Compute collateral hash */
        bytes32 collateralHash = _collateralHash(
            source, collateralToken, collateralTokenId, currencyToken, collateralWrapperContext, liquidationContext
        );

        /* Validate collateral is present */
        if (_getCollateralTrackerStorage().collateralTracker[collateralHash] != CollateralStatus.Present) {
            revert InvalidCollateralState();
        }

        /* Update collateral tracker */
        _getCollateralTrackerStorage().collateralTracker[collateralHash] = CollateralStatus.Withdrawn;

        /* Transfer collateral to caller */
        IERC721(collateralToken).safeTransferFrom(address(this), msg.sender, collateralTokenId);

        /* Emit CollateralWithdrawn */
        emit CollateralWithdrawn(collateralHash, source, collateralToken, collateralTokenId);
    }

    /**
     * @notice Liquidate collateral
     *
     * Emits a {CollateralLiquidated} event.
     *
     * @param source Source that provided collateral
     * @param collateralToken Collateral token from liquidate parameter earlier
     * @param collateralTokenId Collateral token ID from liquidate parameter earlier
     * @param collateralWrapperContext Collateral wrapper context
     * @param liquidationContext Liquidation context
     */
    function liquidateCollateral(
        address source,
        address currencyToken,
        address collateralToken,
        uint256 collateralTokenId,
        bytes calldata collateralWrapperContext,
        bytes calldata liquidationContext,
        uint256 proceeds
    ) external nonReentrant onlyRole(COLLATERAL_LIQUIDATOR_ROLE) {
        /* Compute collateral hash */
        bytes32 collateralHash = _collateralHash(
            source, collateralToken, collateralTokenId, currencyToken, collateralWrapperContext, liquidationContext
        );

        /* Validate collateral is withdrawn */
        if (_getCollateralTrackerStorage().collateralTracker[collateralHash] != CollateralStatus.Withdrawn) {
            revert InvalidCollateralState();
        }

        /* Transfer proceeds from caller to this contract */
        IERC20(currencyToken).safeTransferFrom(msg.sender, address(this), proceeds);

        /* Transfer proceeds to source */
        IERC20(currencyToken).safeTransfer(source, proceeds);

        /* Delete underlying collateral */
        delete _getCollateralTrackerStorage().collateralTracker[collateralHash];

        /* If transfer is successful and source is a contract, try collateral liquidation callback */
        if (source.code.length > 0) {
            try ICollateralLiquidationReceiver(source).onCollateralLiquidated(liquidationContext, proceeds) {} catch {}
        }

        /* Emit CollateralLiquidated */
        emit CollateralLiquidated(collateralHash, collateralToken, collateralTokenId, proceeds);
    }
}
