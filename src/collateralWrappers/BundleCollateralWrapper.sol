// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import "../interfaces/ICollateralWrapper.sol";

/**
 * @title Bundle Collateral Wrapper
 * @author USD.AI Foundation
 */
contract BundleCollateralWrapper is ICollateralWrapper, ERC721, ReentrancyGuardTransient {
    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Implementation version
     */
    string public constant IMPLEMENTATION_VERSION = "3.0";

    /*------------------------------------------------------------------------*/
    /* Errors */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Invalid caller
     */
    error InvalidCaller();

    /**
     * @notice Invalid context
     */
    error InvalidContext();

    /**
     * @notice Invalid bundle size
     */
    error InvalidSize();

    /*------------------------------------------------------------------------*/
    /* Events */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Emitted when bundle is minted
     * @param tokenId Token ID of the new collateral wrapper token
     * @param account Address that created the bundle
     * @param encodedBundle Encoded bundle data
     */
    event BundleMinted(uint256 indexed tokenId, address indexed account, bytes encodedBundle);

    /**
     * @notice Emitted when bundle is unwrapped
     * @param tokenId Token ID of the bundle collateral wrapper token
     * @param account Address that unwrapped the bundle
     */
    event BundleUnwrapped(uint256 indexed tokenId, address indexed account);

    /*------------------------------------------------------------------------*/
    /* Constructor */
    /*------------------------------------------------------------------------*/

    /**
     * @notice BundleCollateralWrapper constructor
     */
    constructor() ERC721("Bundle Collateral Wrapper", "BCW") {}

    /*------------------------------------------------------------------------*/
    /* Implementation */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ICollateralWrapper
     */
    function name() public pure override(ERC721, ICollateralWrapper) returns (string memory) {
        return "Bundle Collateral Wrapper";
    }

    /**
     * @inheritdoc ERC721
     */
    function symbol() public pure override returns (string memory) {
        return "BCW";
    }

    /**
     * @inheritdoc ICollateralWrapper
     */
    function exists(
        uint256 tokenId_
    ) external view returns (bool) {
        return _ownerOf(tokenId_) != address(0);
    }

    /**
     * @inheritdoc ICollateralWrapper
     */
    function tokenId(
        bytes calldata context
    ) public view returns (uint256) {
        return uint256(_hash(context));
    }

    /**
     * @inheritdoc ICollateralWrapper
     */
    function enumerate(
        uint256 tokenId_,
        bytes calldata context
    ) external view returns (address token, uint256[] memory tokenIds) {
        if (tokenId_ != tokenId(context)) revert InvalidContext();

        /* Get token address from context */
        token = address(uint160(bytes20(context[0:20])));

        /* Compute number of tokens in context */
        uint256 tokenCount = (context.length - 20) / 32;

        /* Instantiate asset info array */
        tokenIds = new uint256[](tokenCount);

        /* Populate asset info array */
        uint256 offset = 20;
        for (uint256 i; i < tokenCount; i++) {
            tokenIds[i] = uint256(bytes32(context[offset:offset + 32]));
            offset += 32;
        }
    }

    /**
     * @inheritdoc ICollateralWrapper
     */
    function enumerateWithQuantities(
        uint256 tokenId_,
        bytes calldata context
    ) external view returns (address token, uint256[] memory tokenIds, uint256[] memory quantities) {
        if (tokenId_ != tokenId(context)) revert InvalidContext();

        /* Get token address from context */
        token = address(uint160(bytes20(context[0:20])));

        /* Compute number of tokens in context */
        uint256 tokenCount = (context.length - 20) / 32;

        /* Instantiate asset info array */
        tokenIds = new uint256[](tokenCount);

        /* Instantiate quantities array */
        quantities = new uint256[](tokenCount);

        /* Populate arrays */
        uint256 offset = 20;
        for (uint256 i; i < tokenCount; i++) {
            tokenIds[i] = uint256(bytes32(context[offset:offset + 32]));
            quantities[i] = 1;
            offset += 32;
        }
    }

    /**
     * @inheritdoc ICollateralWrapper
     */
    function count(
        uint256 tokenId_,
        bytes calldata context
    ) external view returns (uint256) {
        if (tokenId_ != tokenId(context)) revert InvalidContext();

        /* Compute number of tokens in context */
        return (context.length - 20) / 32;
    }

    /**
     * @inheritdoc ICollateralWrapper
     */
    function transferCalldata(
        address token,
        address from,
        address to,
        uint256 tokenId_,
        uint256
    ) external pure returns (address, bytes memory) {
        return (token, abi.encodeWithSelector(IERC721.transferFrom.selector, from, to, tokenId_));
    }

    /*------------------------------------------------------------------------*/
    /* Internal Helpers */
    /*------------------------------------------------------------------------*/

    /**
     * @dev Maximum bundle size
     */
    function MAX_BUNDLE_SIZE() public pure virtual returns (uint256) {
        return 128;
    }

    /**
     * @dev Compute hash of encoded bundle
     * @param encodedBundle Encoded bundle
     * @return bundleTokenId Hash
     */
    function _hash(
        bytes memory encodedBundle
    ) internal view returns (bytes32) {
        /* Take hash of chain ID (32 bytes) concatenated with encoded bundle */
        return keccak256(abi.encodePacked(block.chainid, encodedBundle));
    }

    /*------------------------------------------------------------------------*/
    /* User API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Deposit NFT collateral into contract and mint a BundleCollateralWrapper token
     *
     * Emits a {BundleMinted} event
     *
     * @dev Collateral token and token ids are encoded, hashed and stored as
     * the BundleCollateralWrapper token ID.
     * @param token Collateral token address
     * @param tokenIds List of token IDs
     */
    function mint(
        address token,
        uint256[] calldata tokenIds
    ) external nonReentrant returns (uint256) {
        /* Validate token IDs count */
        if (tokenIds.length == 0 || tokenIds.length > MAX_BUNDLE_SIZE()) revert InvalidSize();

        /* Create encodedBundle */
        bytes memory encodedBundle = abi.encodePacked(token);

        /* For each ERC-721 asset, add to encoded bundle and transfer to this contract */
        for (uint256 i; i < tokenIds.length; i++) {
            encodedBundle = abi.encodePacked(encodedBundle, tokenIds[i]);
            IERC721(token).transferFrom(msg.sender, address(this), tokenIds[i]);
        }

        /* Hash encodedBundle */
        uint256 tokenId_ = uint256(_hash(encodedBundle));

        /* Mint BundleCollateralWrapper token */
        _mint(msg.sender, tokenId_);

        emit BundleMinted(tokenId_, msg.sender, encodedBundle);

        return tokenId_;
    }

    /**
     * Emits a {BundleUnwrapped} event
     *
     * @inheritdoc ICollateralWrapper
     */
    function unwrap(
        uint256 tokenId_,
        bytes calldata context
    ) external nonReentrant {
        if (tokenId_ != tokenId(context)) revert InvalidContext();
        if (msg.sender != ownerOf(tokenId_)) revert InvalidCaller();

        /* Get token address from context */
        address token = address(uint160(bytes20(context[0:20])));

        /* Compute number of token ids */
        uint256 tokenCount = (context.length - 20) / 32;

        _burn(tokenId_);

        /* Transfer assets back to owner of token */
        uint256 offset = 20;
        for (uint256 i; i < tokenCount; i++) {
            IERC721(token).transferFrom(address(this), msg.sender, uint256(bytes32(context[offset:offset + 32])));
            offset += 32;
        }

        emit BundleUnwrapped(tokenId_, msg.sender);
    }

    /*------------------------------------------------------------------------*/
    /* ERC165 interface */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return interfaceId == type(ICollateralWrapper).interfaceId || super.supportsInterface(interfaceId);
    }
}
