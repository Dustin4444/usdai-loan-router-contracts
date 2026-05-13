// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/IInterestRateModel.sol";
import "../interfaces/ILoanRouter.sol";

/**
 * @title Simple Interest Rate Model
 * @author USD.AI Foundation
 */
contract SimpleInterestRateModel is IInterestRateModel {
    using SafeCast for uint256;

    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Fixed point scale
     */
    uint256 internal constant FIXED_POINT_SCALE = 1e18;

    /*------------------------------------------------------------------------*/
    /* Constructor */
    /*------------------------------------------------------------------------*/

    /**
     * @notice SimpleInterestRateModel constructor
     */
    constructor() {}

    /*------------------------------------------------------------------------*/
    /* Internal helpers */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Get loan metrics
     * @param terms Loan terms
     * @return Total weighted rate, principal, interest rate
     */
    function _loanMetrics(
        ILoanRouter.LoanTerms memory terms
    ) internal pure returns (uint256, uint256, uint256) {
        uint256 principal;
        uint256 totalWeightedRate;
        for (uint256 i; i < terms.trancheSpecs.length; i++) {
            principal += terms.trancheSpecs[i].amount;
            totalWeightedRate += terms.trancheSpecs[i].rate * terms.trancheSpecs[i].amount;
        }

        return (principal, totalWeightedRate, totalWeightedRate / principal);
    }

    /*------------------------------------------------------------------------*/
    /* Implementation */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IInterestRateModel
     */
    function INTEREST_RATE_MODEL_NAME() external pure override returns (string memory) {
        return "SimpleInterestRateModel";
    }

    /**
     * @inheritdoc IInterestRateModel
     */
    function INTEREST_RATE_MODEL_VERSION() external pure override returns (string memory) {
        return "1.1";
    }

    /**
     * @inheritdoc IInterestRateModel
     */
    function repayment(
        ILoanRouter.LoanTerms calldata terms,
        uint256 balance,
        uint64 repaymentDeadline,
        uint64 maturity,
        uint64 timestamp
    ) external pure returns (uint256, uint256, uint256[] memory, uint256[] memory, uint64) {
        /* Calculate remaining repayment intervals */
        uint64 remainingRepaymentIntervals = ((maturity - repaymentDeadline) / terms.repaymentInterval) + 1;

        /* Calculate pending repayment intervals */
        uint64 pendingRepaymentIntervals = timestamp < repaymentDeadline
            ? 1
            : uint64(
                Math.min((timestamp - repaymentDeadline) / terms.repaymentInterval + 1, remainingRepaymentIntervals)
            );

        /* Calculate grace period elapsed with clamp on grace period duration */
        uint64 gracePeriodElapsed = timestamp < repaymentDeadline
            ? 0
            : uint64(Math.min(timestamp - repaymentDeadline, terms.gracePeriodDuration));

        /* Compute principal, total weighted rate, and blended interest rate */
        (uint256 principal, uint256 totalWeightedRate, uint256 blendedInterestRate) = _loanMetrics(terms);

        /* Calculate principal payment */
        uint256 principalPayment = balance / remainingRepaymentIntervals;
        uint256 totalPrincipalPayment = remainingRepaymentIntervals == pendingRepaymentIntervals
            ? balance
            : principalPayment * pendingRepaymentIntervals;

        /* Calculate total interest payment */
        uint256 totalInterestPayment;
        uint256 remainingBalance = balance;
        for (uint256 i; i < pendingRepaymentIntervals; i++) {
            /* Calculate interest payment */
            uint256 interestPayment =
                Math.mulDiv(remainingBalance * blendedInterestRate, terms.repaymentInterval, FIXED_POINT_SCALE);

            /* Add interest payment to total interest payment */
            totalInterestPayment += interestPayment;

            /* Simulate new balance after repayment */
            remainingBalance -= principalPayment;

            /* Update remaining repayment intervals */
            remainingRepaymentIntervals--;
        }

        /* Add grace period interest to total interest payment */
        totalInterestPayment += Math.mulDiv(balance * terms.gracePeriodRate, gracePeriodElapsed, FIXED_POINT_SCALE);

        /* Compute tranche repayments */
        uint256 remainingPrincipal = totalPrincipalPayment;
        uint256 remainingInterest = totalInterestPayment;
        uint256[] memory trancheInterests = new uint256[](terms.trancheSpecs.length);
        uint256[] memory tranchePrincipals = new uint256[](terms.trancheSpecs.length);
        for (uint256 i; i < terms.trancheSpecs.length; i++) {
            /* Tranche principal is proportional to tranche amount */
            tranchePrincipals[i] = Math.mulDiv(totalPrincipalPayment, terms.trancheSpecs[i].amount, principal);

            /* Tranche interest is proportional to weighted rate */
            trancheInterests[i] = Math.mulDiv(
                totalInterestPayment, terms.trancheSpecs[i].rate * terms.trancheSpecs[i].amount, totalWeightedRate
            );

            /* Update remaining principal and interest */
            remainingPrincipal -= tranchePrincipals[i];
            remainingInterest -= trancheInterests[i];
        }

        /* Add remaining repayment dust to first tranche's repayment */
        if (remainingPrincipal != 0) tranchePrincipals[0] += remainingPrincipal;
        if (remainingInterest != 0) trancheInterests[0] += remainingInterest;

        return
            (
                totalPrincipalPayment,
                totalInterestPayment,
                tranchePrincipals,
                trancheInterests,
                pendingRepaymentIntervals
            );
    }
}
