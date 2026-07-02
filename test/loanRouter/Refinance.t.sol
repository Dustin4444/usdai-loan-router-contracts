// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {RouterFixture} from "../helpers/RouterFixture.sol";

import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {ILoanRouterV2Hooks} from "src/interfaces/ILoanRouterV2Hooks.sol";

/**
 * @title Refinance test
 * @author USD.AI Foundation
 */
contract LoanRouterV2RefinanceTest is RouterFixture {
    /*------------------------------------------------------------------------*/
    /* Originated loans */
    /*------------------------------------------------------------------------*/

    /* Originated loan */
    ILoanRouterV2.LoanTermsV2 internal loanA;

    /*------------------------------------------------------------------------*/
    /* Setup */
    /*------------------------------------------------------------------------*/

    function setUp() public override {
        /* Deploy the fresh router, timelocks, and roles */
        super.setUp();

        /* Originate two distinct active loans */
        loanA = originateDefault();

        /* Mock the lender refinance hook so the test isolates router accounting */
        vm.mockCall(STAKED_USDAI, abi.encodeWithSelector(ILoanRouterV2Hooks.onLoanRefinanced.selector), "");
    }

    /*------------------------------------------------------------------------*/
    /* Test: refinance preserves loan state */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Refinancing the first loan preserves the router loan state
     */
    function test__RefinanceLoanAPreservesState() public {
        /* Reprice the first loan to 10% APR */
        _assertRefinancePreservesState(loanA, RATE_10_PCT);
    }

    /*------------------------------------------------------------------------*/
    /* Test: refinance changes only the rate */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Refinancing changes only the tranche rate, not principal, collateral, or parties
     */
    function test__RefinanceChangesOnlyRate() public view {
        /* Read the old terms and build the repriced terms */
        ILoanRouterV2.LoanTermsV2 memory oldTerms = loanA;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _reprice(loanA, RATE_10_PCT);

        /* The tranche rate is the only tranche field that changed */
        assertTrue(newTerms.trancheSpecs[0].rate != oldTerms.trancheSpecs[0].rate, "rate unchanged");

        /* The tranche amount is unchanged */
        assertEq(newTerms.trancheSpecs[0].amount, oldTerms.trancheSpecs[0].amount, "amount changed");

        /* The tranche lender is unchanged */
        assertEq(newTerms.trancheSpecs[0].lender, oldTerms.trancheSpecs[0].lender, "lender changed");

        /* The borrower is unchanged */
        assertEq(newTerms.borrower, oldTerms.borrower, "borrower changed");

        /* The currency token is unchanged */
        assertEq(newTerms.currencyToken, oldTerms.currencyToken, "currency changed");

        /* The collateral token is unchanged */
        assertEq(newTerms.collateralToken, oldTerms.collateralToken, "collateral token changed");

        /* The collateral count is unchanged */
        assertEq(newTerms.collateralTokenIds.length, oldTerms.collateralTokenIds.length, "collateral count changed");

        /* The loan duration is unchanged */
        assertEq(newTerms.repaymentSpec.totalDurationDays, oldTerms.repaymentSpec.totalDurationDays, "duration changed");

        /* The repayment day is unchanged */
        assertEq(newTerms.repaymentSpec.day, oldTerms.repaymentSpec.day, "repayment day changed");
    }

    /*------------------------------------------------------------------------*/
    /* Test: reverts */
    /*------------------------------------------------------------------------*/

    /**
     * @notice A caller without the originator role cannot refinance
     */
    function test__RevertWhen_CallerNotRefinancer() public {
        /* Build the new terms */
        ILoanRouterV2.LoanTermsV2 memory newTerms = _reprice(loanA, RATE_10_PCT);

        /* An unauthorized account is rejected */
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        router.refinance(loanA, newTerms);
    }

    /**
     * @notice Changing the principal amount is rejected
     */
    function test__RevertWhen_PrincipalChanged() public {
        /* Build the new terms */
        ILoanRouterV2.LoanTermsV2 memory newTerms = _reprice(loanA, RATE_10_PCT);

        /* Raise the tranche amount so principal no longer matches */
        newTerms.trancheSpecs[0].amount += 1 ether;

        /* The router rejects the mismatched principal */
        vm.prank(users.deployer);
        vm.expectRevert(ILoanRouterV2.InvalidAmount.selector);
        router.refinance(loanA, newTerms);
    }

    /**
     * @notice Refinancing an already refinanced loan is rejected
     */
    function test__RevertWhen_OldLoanNotActive() public {
        /* Build the new terms */
        ILoanRouterV2.LoanTermsV2 memory newTerms = _reprice(loanA, RATE_10_PCT);

        /* Refinance once, clearing the old loan */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms);

        /* Refinancing the cleared loan again reverts */
        vm.prank(users.deployer);
        vm.expectRevert(ILoanRouterV2.InvalidLoanState.selector);
        router.refinance(loanA, newTerms);
    }

    /*------------------------------------------------------------------------*/
    /* Internal helpers */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Refinance an originated loan and assert the router loan state is preserved
     * @param oldTerms Old loan terms
     * @param newRate New per second rate scaled by 1e18
     */
    function _assertRefinancePreservesState(
        ILoanRouterV2.LoanTermsV2 storage oldTerms,
        uint256 newRate
    ) internal {
        /* Read a memory copy of the old terms */
        ILoanRouterV2.LoanTermsV2 memory oldTermsMemory = oldTerms;

        /* Build the new terms with only the rate changed */
        ILoanRouterV2.LoanTermsV2 memory newTerms = _reprice(oldTerms, newRate);

        /* Compute the old and new loan hashes */
        bytes32 oldHash = router.loanTermsHash(oldTermsMemory);

        bytes32 newHash = router.loanTermsHash(newTerms);

        /* Read the old loan state before refinancing */
        (ILoanRouterV2.LoanStatus statusBefore, uint16 countBefore, uint64 originationBefore, uint256 balanceBefore) =
            router.loanState(oldHash);

        /* Old loan is active before refinancing */
        assertEq(uint8(statusBefore), uint8(ILoanRouterV2.LoanStatus.Active), "old loan not active");

        /* Capture the old repayment schedule */
        uint64[] memory scheduleBefore = router.deadlines(oldTermsMemory);

        /* Refinance the loan */
        vm.prank(users.deployer);
        router.refinance(oldTermsMemory, newTerms);

        /* Old loan is marked repaid with its accounting retained */
        (
            ILoanRouterV2.LoanStatus oldStatusAfter,
            uint16 oldCountAfter,
            uint64 oldOriginationAfter,
            uint256 oldBalanceAfter
        ) = router.loanState(oldHash);

        /* Old loan status is repaid */
        assertEq(uint8(oldStatusAfter), uint8(ILoanRouterV2.LoanStatus.Repaid), "old loan not repaid");

        /* Old loan balance is retained */
        assertEq(oldBalanceAfter, balanceBefore, "old balance changed");

        /* Old loan repayment count is retained */
        assertEq(oldCountAfter, countBefore, "old repayment count changed");

        /* Old loan origination timestamp is retained */
        assertEq(oldOriginationAfter, originationBefore, "old origination changed");

        /* Read the new loan state */
        (ILoanRouterV2.LoanStatus newStatus, uint16 newCount, uint64 newOrigination, uint256 newBalance) =
            router.loanState(newHash);

        /* New loan is active */
        assertEq(uint8(newStatus), uint8(ILoanRouterV2.LoanStatus.Active), "new loan not active");

        /* Loan balance carries forward unchanged */
        assertEq(newBalance, balanceBefore, "balance changed");

        /* Repayment count carries forward unchanged */
        assertEq(newCount, countBefore, "repayment count changed");

        /* Origination timestamp carries forward unchanged */
        assertEq(newOrigination, originationBefore, "origination changed");

        /* Read the new repayment schedule */
        uint64[] memory scheduleAfter = router.deadlines(newTerms);

        /* Schedule length is unchanged */
        assertEq(scheduleAfter.length, scheduleBefore.length, "schedule length changed");

        /* Every deadline including the final maturity is unchanged */
        for (uint256 i; i < scheduleBefore.length; i++) {
            assertEq(scheduleAfter[i], scheduleBefore[i], "deadline changed");
        }
    }

    /**
     * @notice Build new loan terms from an originated loan with a repriced first tranche
     * @param oldTerms Old loan terms
     * @param newRate New per second rate scaled by 1e18
     * @return terms Repriced loan terms
     */
    function _reprice(
        ILoanRouterV2.LoanTermsV2 storage oldTerms,
        uint256 newRate
    ) internal view returns (ILoanRouterV2.LoanTermsV2 memory terms) {
        /* Copy the old terms into a fresh memory instance */
        terms = oldTerms;

        /* Change only the first tranche rate */
        terms.trancheSpecs[0].rate = newRate;

        /* Keep the new offer valid past the origination timestamp */
        terms.expiration = uint64(block.timestamp + 30 days);
    }
}
