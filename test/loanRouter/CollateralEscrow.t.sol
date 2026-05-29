// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {RouterFixture} from "../helpers/RouterFixture.sol";

import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";

contract LoanRouterV2CollateralEscrowTest is RouterFixture {
    /*------------------------------------------------------------------------*/
    /* Test: collateral staged in CollateralTimelock */
    /*------------------------------------------------------------------------*/

    function test__Originate_CollateralFromCollateralTimelock() public {
        /* Originate a loan whose collateral is staged in CollateralTimelock */
        ILoanRouterV2.LoanTermsV2 memory loanTerms = originateDefault();

        /* Collateral now belongs to the router */
        assertEq(collateralNft.ownerOf(loanTerms.collateralTokenIds[0]), address(router));

        /* Loan is active */
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(router.loanTermsHash(loanTerms));
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active));
    }
}
