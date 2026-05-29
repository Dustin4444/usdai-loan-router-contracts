// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseTest} from "../Base.t.sol";

import {RatioFeeModel} from "src/fees/RatioFeeModel.sol";
import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {LoanRouterV2} from "src/LoanRouterV2.sol";

contract RatioFeeModelTest is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Fixtures */
    /*------------------------------------------------------------------------*/

    RatioFeeModel internal model;

    function setUp() public override {
        super.setUp();
        model = new RatioFeeModel();
    }

    function _emptyTerms() internal pure returns (ILoanRouterV2.LoanTermsV2 memory terms) {
        // intentionally empty
    }

    function _stateWithBalance(
        uint256 balance
    ) internal pure returns (LoanRouterV2.LoanState memory state) {
        state.balance = balance;
    }

    function _opts(
        RatioFeeModel.Mode mode,
        uint256 rate
    ) internal pure returns (bytes memory) {
        return abi.encode(RatioFeeModel.Options({mode: mode, rate: rate}));
    }

    /*------------------------------------------------------------------------*/
    /* Test: constants */
    /*------------------------------------------------------------------------*/

    function test__FeeModelName_Returns() public view {
        assertEq(model.FEE_MODEL_NAME(), "RatioFeeModel");
    }

    function test__FeeModelVersion_Returns() public view {
        assertEq(model.FEE_MODEL_VERSION(), "1.0");
    }

    /*------------------------------------------------------------------------*/
    /* Test: validateOptions */
    /*------------------------------------------------------------------------*/

    function test__ValidateOptions_AcceptsWellFormed() public view {
        model.validateOptions(_opts(RatioFeeModel.Mode.Balance, 0.01e18));
        model.validateOptions(_opts(RatioFeeModel.Mode.Amount, 0.05e18));
    }

    function test__ValidateOptions_RevertWhen_Malformed() public {
        vm.expectRevert();
        model.validateOptions("");
    }

    /*------------------------------------------------------------------------*/
    /* Test: fee — short-circuits */
    /*------------------------------------------------------------------------*/

    function test__Fee_ZeroRate_BalanceMode_ReturnsZero() public view {
        bytes memory data = _opts(RatioFeeModel.Mode.Balance, 0);
        assertEq(model.fee(_emptyTerms(), _stateWithBalance(100e18), data, 1_000_000 * 1e6), 0);
    }

    function test__Fee_ZeroRate_AmountMode_ReturnsZero() public view {
        bytes memory data = _opts(RatioFeeModel.Mode.Amount, 0);
        assertEq(model.fee(_emptyTerms(), _stateWithBalance(100e18), data, 1_000_000 * 1e6), 0);
    }

    function test__Fee_ZeroBalance_BalanceMode_ReturnsZero() public view {
        bytes memory data = _opts(RatioFeeModel.Mode.Balance, 0.01e18);
        assertEq(model.fee(_emptyTerms(), _stateWithBalance(0), data, 1_000_000 * 1e6), 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: fee — Balance mode */
    /*------------------------------------------------------------------------*/

    function test__Fee_BalanceMode_ComputesPercentageOfBalance() public view {
        /* 1% of 100e18 = 1e18 */
        bytes memory data = _opts(RatioFeeModel.Mode.Balance, 0.01e18);
        assertEq(model.fee(_emptyTerms(), _stateWithBalance(100e18), data, 0), 1e18);
    }

    function test__Fee_BalanceMode_IgnoresAmount() public view {
        /* Balance mode uses state.balance, NOT the amount argument */
        bytes memory data = _opts(RatioFeeModel.Mode.Balance, 0.01e18);
        uint256 a = model.fee(_emptyTerms(), _stateWithBalance(100e18), data, 0);
        uint256 b = model.fee(_emptyTerms(), _stateWithBalance(100e18), data, 12345e18);
        assertEq(a, b);
    }

    function test__Fee_BalanceMode_LargeRate_NoOverflow() public view {
        /* rate = 1e36, balance = 1e18 ⇒ result = 1e18 * 1e36 / 1e18 = 1e36 */
        bytes memory data = _opts(RatioFeeModel.Mode.Balance, 1e36);
        assertEq(model.fee(_emptyTerms(), _stateWithBalance(1e18), data, 0), 1e36);
    }

    /*------------------------------------------------------------------------*/
    /* Test: fee — Amount mode */
    /*------------------------------------------------------------------------*/

    function test__Fee_AmountMode_ComputesPercentageOfAmount() public view {
        /* 5% of 1M raw USDC (1e12) = 5e10 */
        bytes memory data = _opts(RatioFeeModel.Mode.Amount, 0.05e18);
        assertEq(model.fee(_emptyTerms(), _stateWithBalance(0), data, 1_000_000 * 1e6), 5e10);
    }

    function test__Fee_AmountMode_IgnoresBalance() public view {
        bytes memory data = _opts(RatioFeeModel.Mode.Amount, 0.05e18);
        uint256 a = model.fee(_emptyTerms(), _stateWithBalance(0), data, 1_000_000 * 1e6);
        uint256 b = model.fee(_emptyTerms(), _stateWithBalance(9_999_999e18), data, 1_000_000 * 1e6);
        assertEq(a, b);
    }

    /*------------------------------------------------------------------------*/
    /* Test: fee — fuzz */
    /*------------------------------------------------------------------------*/

    function test__Fee_AmountMode_ZeroAmount_ReturnsZero() public view {
        bytes memory data = _opts(RatioFeeModel.Mode.Amount, 0.05e18);
        assertEq(model.fee(_emptyTerms(), _stateWithBalance(0), data, 0), 0);
    }

    function test__Fee_BalanceMode_RateExactly100Percent() public view {
        /* rate = 1e18, balance = 100e18 => fee == balance */
        bytes memory data = _opts(RatioFeeModel.Mode.Balance, 1e18);
        assertEq(model.fee(_emptyTerms(), _stateWithBalance(100e18), data, 0), 100e18);
    }

    function test__Fee_AmountMode_RateExactly100Percent() public view {
        /* rate = 1e18, amount = 1_000_000 * 1e6 => fee == amount */
        bytes memory data = _opts(RatioFeeModel.Mode.Amount, 1e18);
        assertEq(model.fee(_emptyTerms(), _stateWithBalance(0), data, 1_000_000 * 1e6), 1_000_000 * 1e6);
    }

    function test__Fee_BalanceMode_MaxUintBalance() public view {
        /* balance = type(uint256).max, rate = 1e18 => fee == balance */
        bytes memory data = _opts(RatioFeeModel.Mode.Balance, 1e18);
        assertEq(model.fee(_emptyTerms(), _stateWithBalance(type(uint256).max), data, 0), type(uint256).max);
    }

    function test__Fee_AmountMode_MaxUintAmount() public view {
        bytes memory data = _opts(RatioFeeModel.Mode.Amount, 1e18);
        assertEq(model.fee(_emptyTerms(), _stateWithBalance(0), data, type(uint256).max), type(uint256).max);
    }

    function test__Fee_BalanceMode_RevertWhen_MulDivOverflows() public {
        /* balance = type(uint256).max, rate = 2e18 => mulDiv overflows and reverts */
        bytes memory data = _opts(RatioFeeModel.Mode.Balance, 2e18);
        vm.expectRevert();
        model.fee(_emptyTerms(), _stateWithBalance(type(uint256).max), data, 0);
    }

    function test__ValidateOptions_AcceptsExtraTrailingData() public view {
        /* abi.decode tolerates trailing data after a valid Options struct. */
        bytes memory good = _opts(RatioFeeModel.Mode.Balance, 0.01e18);
        bytes memory padded = bytes.concat(good, hex"deadbeef");
        model.validateOptions(padded);
    }

    /*------------------------------------------------------------------------*/
    /* Test: validateOptions rate cap (F-04) */
    /*------------------------------------------------------------------------*/

    function test__ValidateOptions_AcceptsRateExactlyHundredPercent() public view {
        /* rate == 1e18 (== 100%) is the boundary and must be accepted */
        model.validateOptions(_opts(RatioFeeModel.Mode.Balance, 1e18));
    }

    function test__ValidateOptions_RevertWhen_RateAboveHundredPercent() public {
        /* Any rate above 100% must be rejected with InvalidOptions */
        bytes memory data = _opts(RatioFeeModel.Mode.Balance, 1e18 + 1);
        vm.expectRevert(RatioFeeModel.InvalidOptions.selector);
        model.validateOptions(data);
    }

    /*------------------------------------------------------------------------*/
    /* Test: Balance mode unscales by scaleFactor (F-01) */
    /*------------------------------------------------------------------------*/

    function test__Fee_BalanceMode_USDC_NotOverCollected() public view {
        /* 1M USDC principal scales to 1M * 1e12 = 1e24 in 18-decimal state.balance */
        /* 1% Balance fee should be 10,000 USDC = 10_000 * 1e6 unscaled */
        bytes memory data = _opts(RatioFeeModel.Mode.Balance, 0.01e18);
        uint256 scaledBalance = 1_000_000 * 1e6 * 1e12;
        uint256 scaleFactor = 1e12;
        assertEq(model.fee(_emptyTerms(), _stateWithBalance(scaledBalance), data, 0), 10_000 * 1e6 * 1e12);
    }

    /*------------------------------------------------------------------------*/
    /* Test: fee - fuzz */
    /*------------------------------------------------------------------------*/

    function testFuzz_Fee_BalanceMode_MatchesMulDiv(
        uint128 balance,
        uint128 rate
    ) public view {
        bytes memory data = _opts(RatioFeeModel.Mode.Balance, uint256(rate));
        uint256 expected = Math.mulDiv(uint256(balance), uint256(rate), 1e18, Math.Rounding.Ceil);
        assertEq(model.fee(_emptyTerms(), _stateWithBalance(uint256(balance)), data, 0), expected);
    }

    function testFuzz_Fee_AmountMode_MatchesMulDiv(
        uint128 amount,
        uint128 rate
    ) public view {
        bytes memory data = _opts(RatioFeeModel.Mode.Amount, uint256(rate));
        uint256 expected = Math.mulDiv(uint256(amount), uint256(rate), 1e18, Math.Rounding.Ceil);
        assertEq(model.fee(_emptyTerms(), _stateWithBalance(0), data, uint256(amount)), expected);
    }
}
