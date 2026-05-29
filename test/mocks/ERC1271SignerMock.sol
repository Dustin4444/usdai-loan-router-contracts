// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/**
 * @title ERC-1271 contract-signer mock
 * @notice Returns the IERC1271 magic value for the pre-approved digest, otherwise zero
 */
contract ERC1271SignerMock is IERC1271 {
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;

    bytes32 public expectedHash;

    function setExpectedHash(
        bytes32 hash_
    ) external {
        expectedHash = hash_;
    }

    function isValidSignature(
        bytes32 hash,
        bytes memory
    ) external view override returns (bytes4) {
        return hash == expectedHash ? MAGIC_VALUE : bytes4(0);
    }
}
