* LoanRouter v1.1 - 03/03/2026
    * Fix elapsed tranche interest calculation in collateral liquidation.
    * Fix return data sanitization in `_supportsHooksInterface()` to prevent
      DoS by malicious lender.
    * Add `pause()` and `unpause()` APIs.

* DepositTimelock v1.1 - 01/23/2026
    * Add depositor `onDepositWithdrawn()` hook to `withdraw()`.

* SimpleInterestRateModel v1.1 - 12/16/2025
    * Fix principal calculation for final repayment.

* LoanRouter v1.0 - 12/03/2025
    * Initial release.

* DepositTimelock v1.0 - 12/03/2025
    * Initial release.
