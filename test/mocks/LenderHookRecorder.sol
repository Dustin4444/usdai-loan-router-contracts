// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {ILoanRouterV2Hooks} from "src/interfaces/ILoanRouterV2Hooks.sol";
import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";

contract LenderHookRecorder is ILoanRouterV2Hooks, IERC165, IERC721Receiver {
    bool public onLoanOriginatedCalled;
    bool public onLoanRepaymentCalled;
    bool public onLoanFeePaidCalled;
    bool public onLoanLiquidatedCalled;
    bool public onLiquidationProceedsDepositedCalled;

    uint256 public lastRepaymentLoanBalance;
    uint256 public lastRepaymentPrincipal;
    uint256 public lastRepaymentInterest;
    uint256 public lastLiquidationPrincipal;
    uint256 public lastLiquidationInterest;
    uint8 public lastTrancheIndex;

    uint8 public lastFeeSpecIndex;
    ILoanRouterV2.FeeKind public lastFeeKind;
    address public lastFeeModel;
    uint256 public lastFeeAmount;

    function onLoanOriginated(
        ILoanRouterV2.LoanTermsV2 calldata,
        bytes32,
        uint8 trancheIndex
    ) external {
        onLoanOriginatedCalled = true;
        lastTrancheIndex = trancheIndex;
    }

    function onLoanRepayment(
        ILoanRouterV2.LoanTermsV2 calldata,
        bytes32,
        uint8 trancheIndex,
        uint256 loanBalance,
        uint256 principal,
        uint256 interest,
        uint256
    ) external {
        onLoanRepaymentCalled = true;
        lastTrancheIndex = trancheIndex;
        lastRepaymentLoanBalance = loanBalance;
        lastRepaymentPrincipal = principal;
        lastRepaymentInterest = interest;
    }

    function onLoanFeePaid(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        bytes32,
        uint8 feeSpecIndex,
        uint256 fee
    ) external {
        onLoanFeePaidCalled = true;
        lastFeeSpecIndex = feeSpecIndex;
        lastFeeKind = loanTerms.feeSpecs[feeSpecIndex].kind;
        lastFeeModel = loanTerms.feeSpecs[feeSpecIndex].model;
        lastFeeAmount = fee;
    }

    function onLoanLiquidated(
        ILoanRouterV2.LoanTermsV2 calldata,
        bytes32,
        uint8 trancheIndex
    ) external {
        onLoanLiquidatedCalled = true;
        lastTrancheIndex = trancheIndex;
    }

    function onLoanCollateralLiquidated(
        ILoanRouterV2.LoanTermsV2 calldata,
        bytes32,
        uint8 trancheIndex,
        uint256 principal,
        uint256 interest
    ) external {
        onLiquidationProceedsDepositedCalled = true;
        lastTrancheIndex = trancheIndex;
        lastLiquidationPrincipal = principal;
        lastLiquidationInterest = interest;
    }

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
