// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title Deposit Timelock Interface
 * @author USD.AI Foundation
 */
interface ILoanRouter {
    /*------------------------------------------------------------------------*/
    /* Structures */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Deposit type
     * @param DepositTimelock Deposit timelock
     * @param ERC20Permit ERC20 permit
     * @param ERC20Approval ERC20 approval
     */
    enum DepositType {
        DepositTimelock,
        ERC20Permit,
        ERC20Approval
    }

    /**
     * @notice Lender deposit info
     * @param depositType Deposit type
     * @param data Deposit data
     */
    struct LenderDepositInfo {
        DepositType depositType;
        bytes data;
    }

    /**
     * @notice Fee specification for loan
     */
    struct FeeSpec {
        uint256 originationFee;
        uint256 exitFee;
    }

    /**
     * @notice Tranche specification for loan
     */
    struct TrancheSpec {
        address lender;
        uint256 amount;
        uint256 rate;
    }

    /**
     * @notice Loan terms specification
     */
    struct LoanTerms {
        uint64 expiration;
        address borrower;
        address currencyToken;
        address collateralToken;
        uint256 collateralTokenId;
        uint64 duration;
        uint64 repaymentInterval;
        address interestRateModel;
        uint256 gracePeriodRate;
        uint256 gracePeriodDuration;
        FeeSpec feeSpec;
        TrancheSpec[] trancheSpecs;
        bytes collateralWrapperContext;
        bytes options;
    }

    /**
     * @notice Loan status
     * @param Uninitialized Loan has not been initialized
     * @param Active Loan is active
     * @param Repaid Loan has been repaid
     * @param Liquidated Loan has been liquidated
     * @param CollateralLiquidated Loan collateral has been liquidated
     */
    enum LoanStatus {
        Uninitialized,
        Active,
        Repaid,
        Liquidated,
        CollateralLiquidated
    }

    /*------------------------------------------------------------------------*/
    /* Errors */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Invalid deposit type
     */
    error InvalidDepositType();

    /**
     * @notice Invalid amount
     */
    error InvalidAmount();

    /**
     * @notice Invalid address
     */
    error InvalidAddress();

    /**
     * @notice Invalid caller
     */
    error InvalidCaller();

    /**
     * @notice Invalid signature
     */
    error InvalidSignature();

    /**
     * @notice Invalid loan state
     */
    error InvalidLoanState();

    /**
     * @notice Invalid length
     */
    error InvalidLength();

    /**
     * @notice Invalid loan terms
     */
    error InvalidLoanTerms(string reason);

    /*------------------------------------------------------------------------*/
    /* Events */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Emitted when loan is originated
     * @param loanTermsHash Loan terms hash
     * @param borrower Borrower address
     * @param currencyToken Currency token address
     * @param principal Amount of currency token borrowed
     * @param originationFee Amount of origination fee
     */
    event LoanOriginated(
        bytes32 indexed loanTermsHash,
        address indexed borrower,
        address indexed currencyToken,
        uint256 principal,
        uint256 originationFee
    );

    /**
     * n
     * @notice Emitted when lender position is minted
     * @param loanTermsHash Loan terms hash
     * @param lender Lender address
     * @param trancheIndex Tranche index
     * @param tokenId Token ID
     */
    event LenderPositionMinted(
        bytes32 indexed loanTermsHash, address indexed lender, uint8 indexed trancheIndex, uint256 tokenId
    );

    /**
     * @notice Emitted when lender is repaid
     * @param loanTermsHash Loan terms hash
     * @param lender Lender address
     * @param trancheIndex Tranche index
     * @param principal Amount of principal repaid
     * @param interest Amount of interest repaid
     * @param prepay Amount of prepayment
     */
    event LenderRepaid(
        bytes32 indexed loanTermsHash,
        address indexed lender,
        uint8 indexed trancheIndex,
        uint256 principal,
        uint256 interest,
        uint256 prepay
    );

    /**
     * @notice Emitted when loan is repaid
     * @param loanTermsHash Loan terms hash
     * @param borrower Borrower address
     * @param principal Amount of principal repaid
     * @param interest Amount of interest repaid
     * @param prepayment Amount of prepayment
     * @param exitFee Amount of exit fee
     * @param isRepaid Whether loan is repaid
     */
    event LoanRepaid(
        bytes32 indexed loanTermsHash,
        address indexed borrower,
        uint256 principal,
        uint256 interest,
        uint256 prepayment,
        uint256 exitFee,
        bool isRepaid
    );

    /**
     * @notice Emitted when loan is liquidated
     * @param loanTermsHash Loan terms hash
     */
    event LoanLiquidated(bytes32 indexed loanTermsHash);

    /**
     * @notice Emitted when lender is liquidation repaid
     * @param loanTermsHash Loan terms hash
     * @param lender Lender address
     * @param trancheIndex Tranche index
     * @param principal Amount of principal repaid
     * @param interest Amount of interest repaid
     */
    event LenderLiquidationRepaid(
        bytes32 indexed loanTermsHash,
        address indexed lender,
        uint8 indexed trancheIndex,
        uint256 principal,
        uint256 interest
    );

    /**
     * @notice Emitted when collateral is liquidated
     * @param loanTermsHash Loan terms hash
     * @param proceeds Proceeds for lenders
     * @param liquidationFee Liquidation fee
     * @param surplus Surplus
     */
    event LoanCollateralLiquidated(
        bytes32 indexed loanTermsHash, uint256 proceeds, uint256 liquidationFee, uint256 surplus
    );

    /**
     * @notice Emitted when transfer failed
     * @param token Token address
     * @param recipient Recipient address
     * @param intendedRecipient Intended recipient address
     * @param amount Amount
     */
    event TransferFailed(
        address indexed token, address indexed recipient, address indexed intendedRecipient, uint256 amount
    );

    /**
     * @notice Emitted when hook failed
     * @param reason Reason
     */
    event HookFailed(string reason);

    /**
     * @notice Emitted when nonce is increased
     * @param loanTermsHash Loan terms hash
     * @param lender Lender address
     * @param nonce Nonce
     */
    event NonceIncreased(bytes32 indexed loanTermsHash, address indexed lender, uint256 nonce);

    /**
     * @notice Emitted when fee recipient is set
     * @param recipient Fee recipient
     */
    event FeeRecipientSet(address indexed recipient);

    /**
     * @notice Emitted when liquidation fee rate is set
     * @param liquidationFeeRate Liquidation fee rate
     */
    event LiquidationFeeRateSet(uint256 indexed liquidationFeeRate);

    /*------------------------------------------------------------------------*/
    /* Getters */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Get deposit timelock
     * @return Deposit timelock address
     */
    function depositTimelock() external view returns (address);

    /**
     * @notice Compute loan terms hash from loan terms sturcture
     * @param loanTerms Loan terms
     * @return Loan terms hash
     */
    function loanTermsHash(
        LoanTerms calldata loanTerms
    ) external view returns (bytes32);

    /**
     * @notice Get loan lending position token IDs
     * @param loanTerms Loan terms
     * @return Token IDs
     */
    function loanTokenIds(
        LoanTerms calldata loanTerms
    ) external view returns (uint256[] memory);

    /**
     * @notice Get loan state by loan terms hash
     * @param loanTermsHash Loan terms hash
     * @return status Loan status
     * @return maturity Loan maturity timestamp
     * @return repaymentDeadline Deadline for next repayment
     * @return scaledBalance Scaled loan balance (18 decimal)
     */
    function loanState(
        bytes32 loanTermsHash
    ) external view returns (LoanStatus status, uint64 maturity, uint64 repaymentDeadline, uint256 scaledBalance);

    /**
     * @notice Get loan state by token ID
     * @param tokenId Lender position token ID
     * @return status Loan status
     * @return maturity Loan maturity timestamp
     * @return repaymentDeadline Deadline for next repayment
     * @return scaledBalance Scaled loan balance (18 decimal)
     */
    function loanState(
        uint256 tokenId
    ) external view returns (LoanStatus status, uint64 maturity, uint64 repaymentDeadline, uint256 scaledBalance);

    /**
     * @notice Get lending position info by token ID
     * @param tokenId Lender position token ID
     * @return loanTermsHash Loan terms hash
     * @return trancheIndex Tranche index
     */
    function lendingPositionInfo(
        uint256 tokenId
    ) external view returns (bytes32 loanTermsHash, uint8 trancheIndex);

    /*------------------------------------------------------------------------*/
    /* Public API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Borrow funds from lenders
     * @param loanTerms Loan terms
     * @param lenderDepositInfos Lender deposit infos
     */
    function borrow(
        LoanTerms calldata loanTerms,
        LenderDepositInfo[] calldata lenderDepositInfos
    ) external;

    /**
     * @notice Quote repayment for loan
     * @param loanTerms Loan terms
     * @return principalPayment Principal payment
     * @return interestPayment Interest payment
     * @return feesPayment Fees payment
     */
    function quote(
        LoanTerms calldata loanTerms
    ) external view returns (uint256 principalPayment, uint256 interestPayment, uint256 feesPayment);

    /**
     * @notice Quote repayment for loan
     * @param loanTerms Loan terms
     * @param timestamp Repayment timestamp
     * @return principalPayment Principal payment
     * @return interestPayment Interest payment
     * @return feesPayment Fees payment
     */
    function quote(
        LoanTerms calldata loanTerms,
        uint64 timestamp
    ) external view returns (uint256 principalPayment, uint256 interestPayment, uint256 feesPayment);

    /**
     * @notice Repay loan with optional prepayment
     * @param loanTerms Loan terms
     * @param amount Amount
     */
    function repay(
        LoanTerms calldata loanTerms,
        uint256 amount
    ) external;

    /**
     * @notice Liquidate loan after grace period
     * @param loanTerms Loan terms
     */
    function liquidate(
        LoanTerms calldata loanTerms
    ) external;

    /**
     * @notice Called by liquidator when collateral is liquidated
     * @param encodedLoanTerms Encoded loan terms
     * @param proceeds Proceeds from collateral liquidation
     */
    function onCollateralLiquidated(
        bytes calldata encodedLoanTerms,
        uint256 proceeds
    ) external;

    /**
     * @notice Increase nonce
     * @param loanTerms Loan terms
     */
    function increaseNonce(
        LoanTerms calldata loanTerms
    ) external;

    /*------------------------------------------------------------------------*/
    /* Admin API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Pause (admin only)
     */
    function pause() external;

    /**
     * @notice Unpause (admin only)
     */
    function unpause() external;

    /**
     * @notice Set fee recipient (admin only)
     * @param recipient Fee recipient address
     */
    function setFeeRecipient(
        address recipient
    ) external;

    /**
     * @notice Set liquidation fee rate (admin only)
     * @param liquidationFeeRate Liquidation fee rate
     */
    function setLiquidationFeeRate(
        uint256 liquidationFeeRate
    ) external;
}
