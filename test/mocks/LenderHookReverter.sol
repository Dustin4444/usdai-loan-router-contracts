// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {ILoanRouterV1} from "src/interfaces/ILoanRouterV1.sol";
import {ILoanRouterV2Hooks} from "src/interfaces/ILoanRouterV2Hooks.sol";
import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";

contract LenderHookReverter is ILoanRouterV2Hooks, IERC165, IERC721Receiver {
    error HookIntentionallyReverted();

    function onLoanOriginated(
        ILoanRouterV2.LoanTermsV2 calldata,
        bytes32,
        uint8
    ) external pure {}

    function onLoanRepayment(
        ILoanRouterV2.LoanTermsV2 calldata,
        bytes32,
        uint8,
        uint256,
        uint256,
        uint256,
        uint256
    ) external pure {
        revert HookIntentionallyReverted();
    }

    function onLoanFeePaid(
        ILoanRouterV2.LoanTermsV2 calldata,
        bytes32,
        uint8,
        uint256
    ) external pure {
        revert HookIntentionallyReverted();
    }

    function onLoanLiquidated(
        ILoanRouterV2.LoanTermsV2 calldata,
        bytes32,
        uint8
    ) external pure {
        revert HookIntentionallyReverted();
    }

    function onLoanCollateralLiquidated(
        ILoanRouterV2.LoanTermsV2 calldata,
        bytes32,
        uint8,
        uint256,
        uint256
    ) external pure {
        revert HookIntentionallyReverted();
    }

    function onLoanMigrated(
        ILoanRouterV1.LoanTerms calldata,
        bytes32,
        ILoanRouterV2.LoanTermsV2 calldata,
        bytes32,
        uint64
    ) external {}

    function supportsInterface(
        bytes4 interfaceId
    ) external pure returns (bool) {
        return interfaceId == type(ILoanRouterV2Hooks).interfaceId || interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IERC721Receiver).interfaceId;
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
