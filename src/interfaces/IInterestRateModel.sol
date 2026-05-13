// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./ILoanRouter.sol";

/**
 * @title Interest Rate Model Interface
 * @author USD.AI Foundation
 */
interface IInterestRateModel {
    /*------------------------------------------------------------------------*/
    /* API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Get interest rate model name
     * @return Interest rate model name
     */
    function INTEREST_RATE_MODEL_NAME() external view returns (string memory);

    /**
     * @notice Get interest rate model version
     * @return Interest rate model version
     */
    function INTEREST_RATE_MODEL_VERSION() external view returns (string memory);

    /**
     * @notice Price repayment
     * @param terms Loan terms
     * @param balance Loan balance
     * @param repaymentDeadline Last repayment timestamp
     * @param maturity Loan maturity timestamp
     * @param timestamp Current timestamp or maturity timestamp
     * @return principalPayment Principal payment
     * @return interestPayment Interest payment
     * @return trachePrincipals Tranche principals
     * @return tracheInterests Tranche interests
     * @return servicedIntervals Serviced intervals
     */
    function repayment(
        ILoanRouter.LoanTerms calldata terms,
        uint256 balance,
        uint64 repaymentDeadline,
        uint64 maturity,
        uint64 timestamp
    )
        external
        view
        returns (
            uint256 principalPayment,
            uint256 interestPayment,
            uint256[] memory trachePrincipals,
            uint256[] memory tracheInterests,
            uint64 servicedIntervals
        );
}
