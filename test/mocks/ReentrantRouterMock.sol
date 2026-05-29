// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {IReserveAccount} from "src/interfaces/IReserveAccount.sol";

contract ReentrantRouterMock {
    IReserveAccount public reserve;
    uint256 public quoteTotal;

    function setReserve(
        address reserve_
    ) external {
        reserve = IReserveAccount(reserve_);
    }

    function setQuoteTotal(
        uint256 quoteTotal_
    ) external {
        quoteTotal = quoteTotal_;
    }

    function quote(
        ILoanRouterV2.LoanTermsV2 calldata
    ) external view returns (uint256, uint256, uint256) {
        return (quoteTotal, 0, 0);
    }

    function repay(
        ILoanRouterV2.LoanTermsV2 calldata,
        uint256
    ) external {
        // Reenter into the reserve - should be blocked by the nonReentrant guard.
        reserve.withdraw(address(0xdead), 1);
    }
}
