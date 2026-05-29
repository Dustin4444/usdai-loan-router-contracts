// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {BaseTest} from "../Base.t.sol";

import {AbsoluteFeeModel} from "src/fees/AbsoluteFeeModel.sol";
import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {LoanRouterV2} from "src/LoanRouterV2.sol";

contract AbsoluteFeeModelTest is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Fixtures */
    /*------------------------------------------------------------------------*/

    AbsoluteFeeModel internal model;

    function setUp() public override {
        super.setUp();
        model = new AbsoluteFeeModel();
    }

    function _terms(
        address currencyToken
    ) internal pure returns (ILoanRouterV2.LoanTermsV2 memory terms) {
        terms.currencyToken = currencyToken;
    }

    function _state(
        uint16 repaymentCount
    ) internal pure returns (LoanRouterV2.LoanState memory state) {
        state.repaymentCount = repaymentCount;
    }

    function _opts(
        uint256 amount
    ) internal pure returns (bytes memory) {
        return abi.encode(AbsoluteFeeModel.Options({amount: amount}));
    }

    /*------------------------------------------------------------------------*/
    /* Test: constants */
    /*------------------------------------------------------------------------*/

    function test__FeeModelName_Returns() public view {
        assertEq(model.FEE_MODEL_NAME(), "AbsoluteFeeModel");
    }

    function test__FeeModelVersion_Returns() public view {
        assertEq(model.FEE_MODEL_VERSION(), "1.0");
    }

    /*------------------------------------------------------------------------*/
    /* Test: validateOptions */
    /*------------------------------------------------------------------------*/

    function test__ValidateOptions_AcceptsWellFormed() public view {
        model.validateOptions(_opts(100)); /* must not revert */
    }

    function test__ValidateOptions_RevertWhen_Malformed() public {
        vm.expectRevert();
        model.validateOptions("");
    }

    /*------------------------------------------------------------------------*/
    /* Test: fee */
    /*------------------------------------------------------------------------*/

    function test__Fee_ScalesAmount_StateIndependent() public view {
        /* USDC has 6 decimals so the scale factor is 1e12 */
        bytes memory data = _opts(123);
        uint256 expected = 123 * 1e12;
        assertEq(model.fee(_terms(USDC), _state(0), data, 0), expected);
        assertEq(model.fee(_terms(USDC), _state(1), data, 0), expected);
        assertEq(model.fee(_terms(USDC), _state(99), data, 0), expected);
        assertEq(model.fee(_terms(USDC), _state(0), data, 0), expected);
        assertEq(model.fee(_terms(USDC), _state(7), data, 0), expected);
    }

    function test__Fee_PrincipalIgnored() public view {
        /* USDC scale factor is 1e12 */
        bytes memory data = _opts(500);
        uint256 expected = 500 * 1e12;
        assertEq(model.fee(_terms(USDC), _state(0), data, 0), expected);
        assertEq(model.fee(_terms(USDC), _state(0), data, 1e30), expected);
    }

    function test__Fee_EighteenDecimalToken_ScaleFactorOne() public view {
        /* USDAI has 18 decimals so the scale factor is 1 and the fee equals the amount */
        bytes memory data = _opts(777);
        assertEq(model.fee(_terms(USDAI), _state(0), data, 0), 777);
    }

    function test__Fee_ZeroAmount_ReturnsZero() public view {
        /* Zero amount scales to zero on any token */
        bytes memory data = _opts(0);
        assertEq(model.fee(_terms(USDC), _state(0), data, 0), 0);
        assertEq(model.fee(_terms(USDC), _state(5), data, 0), 0);
    }
}
