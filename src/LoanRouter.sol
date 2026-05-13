// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/TransientSlot.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import "./interfaces/ILoanRouter.sol";
import "./interfaces/IInterestRateModel.sol";
import "./interfaces/IDepositTimelock.sol";
import "./interfaces/ILoanRouterHooks.sol";
import "./interfaces/external/ICollateralLiquidator.sol";
import "./interfaces/external/ICollateralLiquidationReceiver.sol";
import "./interfaces/ICollateralWrapper.sol";

import "./libs/ExcessivelySafeCall.sol";

import "./LoanTermsLogic.sol";

/**
 * @title Loan Router
 * @author USD.AI Foundation
 */
contract LoanRouter is
    ILoanRouter,
    ERC165Upgradeable,
    ERC721EnumerableUpgradeable,
    EIP712Upgradeable,
    PausableUpgradeable,
    MulticallUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;
    using TransientSlot for *;
    using ExcessivelySafeCall for *;

    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Implementation version
     */
    string public constant IMPLEMENTATION_VERSION = "1.1";

    /**
     * @notice Basis points scale
     */
    uint256 internal constant BASIS_POINTS_SCALE = 10_000;

    /**
     * @notice Hook gas limit
     */
    uint256 internal constant HOOK_GAS_LIMIT = 500_000;

    /**
     * @notice Supports interface gas limit
     */
    uint256 internal constant SUPPORTS_INTERFACE_GAS_LIMIT = 12_000;

    /**
     * @notice Pause role
     */
    bytes32 internal constant PAUSE_ADMIN_ROLE = keccak256("PAUSE_ADMIN_ROLE");

    /**
     * @notice Scaling factor transient slot
     * @dev keccak256(abi.encode(uint256(keccak256("loanRouter.scalingFactor")) - 1)) & ~bytes32(uint256(0xff));
     */
    bytes32 private constant SCALING_FACTOR_STORAGE_LOCATION =
        0xe461c638b6ad5cd13161c294fe280cbb25e1510e2f255e3911825d0ed7ae9300;

    /**
     * @notice Loans storage location
     * @dev keccak256(abi.encode(uint256(keccak256("loanRouter.loans")) - 1)) & ~bytes32(uint256(0xff));
     */
    bytes32 private constant LOANS_STORAGE_LOCATION =
        0xbed161479eb3ab41274a425eb55ec68f417f61351656d9f467f8de5f3abc5300;

    /**
     * @notice Fee storage location
     * @dev keccak256(abi.encode(uint256(keccak256("loanRouter.fee")) - 1)) & ~bytes32(uint256(0xff));
     */
    bytes32 private constant FEE_STORAGE_LOCATION = 0x729b785f16144c742628debd3fa4b231d35b2e63cd0dbb835d778496370cf100;

    /*------------------------------------------------------------------------*/
    /* Structures */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Loan state
     * @param status Loan status
     * @param maturity Loan maturity timestamp
     * @param repaymentDeadline Repayment deadline
     * @param balance Loan balance
     * @param nonces Lender signature nonces
     */
    struct LoanState {
        LoanStatus status;
        uint64 maturity;
        uint64 repaymentDeadline;
        uint256 balance;
        mapping(address => uint256) nonces;
    }

    /**
     * @notice Loan reverse lookup
     * @param loanTermsHash Loan terms hash
     * @param trancheIndex Tranche index
     */
    struct LoanReverseLookup {
        bytes32 loanTermsHash;
        uint8 trancheIndex;
    }

    /**
     * @custom:storage-location erc7201:loanRouter.loans
     */
    struct Loans {
        mapping(bytes32 => LoanState) loans;
        mapping(uint256 => LoanReverseLookup) loanReverseLookups;
    }

    /**
     * @custom:storage-location erc7201:loanRouter.fee
     */
    struct Fee {
        address recipient;
        uint256 liquidationFeeRate;
    }

    /*------------------------------------------------------------------------*/
    /* Immutable state */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Deposit timelock
     */
    address internal immutable _depositTimelock;

    /**
     * @notice Collateral liquidator
     */
    address internal immutable _collateralLiquidator;

    /**
     * @notice Collateral wrapper
     */
    address internal immutable _collateralWrapper;

    /*------------------------------------------------------------------------*/
    /* Constructor */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Loan Router Constructor
     * @param depositTimelock_ Deposit timelock
     * @param collateralLiquidator_ Collateral liquidator
     * @param collateralWrapper_ Collateral wrapper
     */
    constructor(
        address depositTimelock_,
        address collateralLiquidator_,
        address collateralWrapper_
    ) {
        _disableInitializers();

        _depositTimelock = depositTimelock_;
        _collateralLiquidator = collateralLiquidator_;
        _collateralWrapper = collateralWrapper_;
    }

    /*------------------------------------------------------------------------*/
    /* Initialization  */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Initialize the contract
     * @param admin Default admin address
     * @param feeRecipient Fee recipient address
     * @param liquidationFeeRate Liquidation fee rate
     */
    function initialize(
        address admin,
        address feeRecipient,
        uint256 liquidationFeeRate
    ) external initializer {
        __ERC165_init();
        __ERC721_init("USDai Loan Router", "USDai-LR");
        __EIP712_init("USDai Loan Router", "1.0");
        __Multicall_init();
        __AccessControl_init();

        _getFeeStorage().recipient = feeRecipient;
        _getFeeStorage().liquidationFeeRate = liquidationFeeRate;

        /* Grant roles */
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /*------------------------------------------------------------------------*/
    /* Modifiers  */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Non-zero value modifier
     * @param value Value to check
     */
    modifier nonZeroUint(
        uint256 value
    ) {
        if (value == 0) revert InvalidAmount();
        _;
    }

    /**
     * @notice Non-zero address modifier
     * @param value Value to check
     */
    modifier nonZeroAddress(
        address value
    ) {
        if (value == address(0)) revert InvalidAddress();
        _;
    }

    /**
     * @notice Store scale factor in transient storage modifier
     * @param currencyToken Currency token
     */
    modifier scaleFactor(
        address currencyToken
    ) {
        /* Store scale factor in transient storage location */
        SCALING_FACTOR_STORAGE_LOCATION.asUint256().tstore(10 ** (18 - IERC20Metadata(currencyToken).decimals()));

        _;

        /* Reset scale factor */
        SCALING_FACTOR_STORAGE_LOCATION.asUint256().tstore(0);
    }

    /*------------------------------------------------------------------------*/
    /* Storage getters */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Get reference to loans storage
     *
     * @return $ Reference to loans storage
     */
    function _getLoansStorage() internal pure returns (Loans storage $) {
        assembly {
            $.slot := LOANS_STORAGE_LOCATION
        }
    }

    /**
     * @notice Get reference to fee storage
     *
     * @return $ Reference to fee storage
     */
    function _getFeeStorage() internal pure returns (Fee storage $) {
        assembly {
            $.slot := FEE_STORAGE_LOCATION
        }
    }

    /*------------------------------------------------------------------------*/
    /* Internal helpers */
    /*------------------------------------------------------------------------*/

    /**
     * @dev Helper function to scale up a value
     * @param value Value
     * @return Scaled value
     */
    function _scale(
        uint256 value
    ) internal view returns (uint256) {
        return value * SCALING_FACTOR_STORAGE_LOCATION.asUint256().tload();
    }

    /**
     * @dev Helper function to scale down a value
     * @param value Value
     * @param roundUp Round up if true
     * @return Unscaled value
     */
    function _unscale(
        uint256 value,
        bool roundUp
    ) internal view returns (uint256) {
        /* Get scale factor */
        uint256 scaleFactor_ = SCALING_FACTOR_STORAGE_LOCATION.asUint256().tload();

        /* Round down if not rounding up */
        return (value % scaleFactor_ == 0 || !roundUp) ? value / scaleFactor_ : value / scaleFactor_ + 1;
    }

    /**
     * @dev Helper function to scale down a value
     * @param value Value
     * @return Unscaled value
     */
    function _unscale(
        uint256 value
    ) internal view returns (uint256) {
        return _unscale(value, false);
    }

    /**
     * @notice Compute loan terms hash from struct
     * @param loanTerms Loan terms struct
     * @return Loan terms hash
     */
    function _hashLoanTerms(
        LoanTerms memory loanTerms
    ) internal view returns (bytes32) {
        /* Use abi.encode for struct hashing to avoid stack too deep */
        return keccak256(abi.encode(block.chainid, loanTerms));
    }

    /**
     * @notice Calculate loan principal
     * @param loanTerms Loan terms
     * @return Principal
     */
    function _calculatePrincipal(
        LoanTerms calldata loanTerms
    ) internal pure returns (uint256) {
        uint256 principal;
        for (uint8 i; i < loanTerms.trancheSpecs.length; i++) {
            principal += loanTerms.trancheSpecs[i].amount;
        }
        return principal;
    }

    /**
     * @notice Validate lender signatures and submits permit if required
     * @param loanTerms Loan terms
     * @param loanState_ Loan state
     * @param lenderDepositInfos Lender deposit infos
     */
    function _validateLenderSignatures(
        LoanTerms calldata loanTerms,
        LoanState storage loanState_,
        LenderDepositInfo[] calldata lenderDepositInfos
    ) internal {
        for (uint8 i; i < lenderDepositInfos.length; i++) {
            if (lenderDepositInfos[i].depositType == DepositType.DepositTimelock) continue;

            /* Get lender signature */
            bytes memory lenderSignature;

            /* Decode deposit data */
            if (lenderDepositInfos[i].depositType == DepositType.ERC20Permit) {
                /* Decode ERC20 permit data and lender signature */
                (uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s, bytes memory lenderSignature_) =
                    abi.decode(lenderDepositInfos[i].data, (uint256, uint256, uint8, bytes32, bytes32, bytes));

                /* Call IERC20 permit */
                IERC20Permit(loanTerms.currencyToken)
                    .permit(loanTerms.trancheSpecs[i].lender, address(this), value, deadline, v, r, s);

                /* Set lender signature */
                lenderSignature = lenderSignature_;
            } else if (lenderDepositInfos[i].depositType == DepositType.ERC20Approval) {
                /* Get lender signature */
                lenderSignature = lenderDepositInfos[i].data;
            } else {
                /* Invalid deposit type */
                revert InvalidDepositType();
            }

            /* Recover loan terms signer */
            address signer = ECDSA.recover(
                _hashTypedDataV4(
                    LoanTermsLogic.hashLoanTermsWithNonce(
                        loanTerms, loanState_.nonces[loanTerms.trancheSpecs[i].lender]
                    )
                ),
                lenderSignature
            );

            /* Validate signer */
            if (signer != loanTerms.trancheSpecs[i].lender) revert InvalidSignature();
        }
    }

    /**
     * @notice Get token ID of lender position
     * @param loanTermsHash_ Loan terms hash
     * @param trancheIndex Tranche index
     * @return tokenId Token ID
     */
    function _tokenId(
        bytes32 loanTermsHash_,
        uint8 trancheIndex
    ) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(loanTermsHash_, trancheIndex)));
    }

    /**
     * @notice Borrow funds
     * @param loanTerms Loan terms
     * @param loanTermsHash_ Loan terms hash
     * @param lenderDepositInfos Lender deposit infos
     */
    function _borrowFunds(
        LoanTerms calldata loanTerms,
        bytes32 loanTermsHash_,
        LenderDepositInfo[] calldata lenderDepositInfos
    ) internal {
        /* Transfer borrow token to lender */
        for (uint8 i; i < loanTerms.trancheSpecs.length; i++) {
            if (lenderDepositInfos[i].depositType == DepositType.DepositTimelock) {
                /* Withdraw borrow token from deposit timelock */
                IDepositTimelock(_depositTimelock)
                    .withdraw(
                        loanTermsHash_,
                        loanTerms.trancheSpecs[i].lender,
                        loanTerms.currencyToken,
                        loanTerms.trancheSpecs[i].amount,
                        lenderDepositInfos[i].data
                    );
            } else {
                /* Transfer borrow token from lender */
                IERC20(loanTerms.currencyToken)
                    .safeTransferFrom(loanTerms.trancheSpecs[i].lender, address(this), loanTerms.trancheSpecs[i].amount);
            }
        }
    }

    /**
     * @notice Tokenize lending positions
     * @param loanTerms Loan terms
     * @param loanTermsHash_ Loan terms hash
     */
    function _tokenizeLendingPositions(
        LoanTerms calldata loanTerms,
        bytes32 loanTermsHash_
    ) internal {
        /* Transfer tokenized lending positions to lenders */
        for (uint8 i; i < loanTerms.trancheSpecs.length; i++) {
            /* Get token ID */
            uint256 tokenId = _tokenId(loanTermsHash_, i);

            /* Get lender */
            address lender = loanTerms.trancheSpecs[i].lender;

            /* Validate no hash collision */
            if (_getLoansStorage().loanReverseLookups[tokenId].loanTermsHash != bytes32(0)) {
                revert InvalidLoanState();
            }

            /* Store loan lookup */
            _getLoansStorage().loanReverseLookups[tokenId] =
                LoanReverseLookup({loanTermsHash: loanTermsHash_, trancheIndex: i});

            /* Mint tokenized lending position to lender */
            _safeMint(lender, tokenId);

            /* Call onLoanOriginated hook if lender is a contract and implements ILoanRouterHooks interface */
            if (lender.code.length != 0 && IERC165(lender).supportsInterface(type(ILoanRouterHooks).interfaceId)) {
                ILoanRouterHooks(lender).onLoanOriginated(loanTerms, loanTermsHash_, i);
            }

            /* Emit lender position minted event */
            emit LenderPositionMinted(loanTermsHash_, lender, i, tokenId);
        }
    }

    /**
     * @notice Repay lenders
     * @param loanTerms Loan terms
     * @param loanTermsHash_ Loan terms hash
     * @param loanBalance Loan balance
     * @param trancheInterests Tranche interests
     * @param tranchePrincipals Tranche principals
     * @param totalPrepayment Total prepayment
     * @return Total repayment transferred
     */
    function _repayLenders(
        LoanTerms calldata loanTerms,
        bytes32 loanTermsHash_,
        uint256 loanBalance,
        uint256[] memory trancheInterests,
        uint256[] memory tranchePrincipals,
        uint256 totalPrepayment
    ) internal returns (uint256) {
        /* Unscale loan balance */
        loanBalance = _unscale(loanBalance);

        /* Calculate original principal to prorate prepayment */
        uint256 originalPrincipal = totalPrepayment != 0 ? _calculatePrincipal(loanTerms) : 0;

        uint256 totalRepayment;
        uint256 totalPrepaymentRemaining = totalPrepayment;
        for (uint8 i; i < loanTerms.trancheSpecs.length; i++) {
            /* Calculate prepayment for this tranche */
            uint256 tranchePrepayment = totalPrepayment != 0
                ? (i == loanTerms.trancheSpecs.length - 1)
                    ? totalPrepaymentRemaining
                    : Math.mulDiv(totalPrepayment, loanTerms.trancheSpecs[i].amount, originalPrincipal)
                : 0;
            totalPrepaymentRemaining -= tranchePrepayment;

            /* Calculate unscaled principal, interest, prepayment, and total repayment */
            uint256 principal = _unscale(tranchePrincipals[i]);
            uint256 interest = _unscale(trancheInterests[i]);
            uint256 prepayment = _unscale(tranchePrepayment);
            uint256 repayment = principal + interest + prepayment;

            /* Accumulate total repayment */
            totalRepayment += repayment;

            /* Get tranche owner */
            address owner = _ownerOf(_tokenId(loanTermsHash_, i));

            /* Transfer unscaled repayment amount from this contract to token owner */
            if (repayment > 0) {
                try IERC20(loanTerms.currencyToken).transfer(owner, repayment) returns (bool success) {
                    if (!success) _redirectRepayment(IERC20(loanTerms.currencyToken), owner, repayment);
                } catch {
                    _redirectRepayment(IERC20(loanTerms.currencyToken), owner, repayment);
                }
            }

            /* Call onLoanRepayment hook if lender is a contract and implements ILoanRouterHooks interface */
            if (_supportsHooksInterface(owner)) {
                try ILoanRouterHooks(owner).onLoanRepayment{gas: HOOK_GAS_LIMIT}(
                    loanTerms, loanTermsHash_, i, loanBalance, principal, interest, prepayment
                ) {}
                catch (bytes memory reason) {
                    /* Emit hook failed event */
                    emit HookFailed(string(reason));
                }
            }

            /* Emit lender repaid event */
            emit LenderRepaid(loanTermsHash_, owner, i, principal, interest, prepayment);
        }

        return totalRepayment;
    }

    /**
     * @notice Repay lenders liquidation proceeds
     * @param loanTerms Loan terms
     * @param loanTermsHash_ Loan terms hash
     * @param trancheInterests Tranche interests
     * @param tranchePrincipals Tranche principals
     */
    function _repayLendersLiquidation(
        LoanTerms memory loanTerms,
        bytes32 loanTermsHash_,
        uint256[] memory trancheInterests,
        uint256[] memory tranchePrincipals
    ) internal {
        for (uint8 i; i < loanTerms.trancheSpecs.length; i++) {
            /* Calculate unscaled principal, interest, prepayment, and total repayment */
            uint256 principal = _unscale(tranchePrincipals[i]);
            uint256 interest = _unscale(trancheInterests[i]);
            uint256 repayment = principal + interest;

            /* Get tranche owner */
            address owner = _ownerOf(_tokenId(loanTermsHash_, i));

            /* Transfer unscaled repayment amount from this contract to token owner */
            if (repayment > 0) {
                try IERC20(loanTerms.currencyToken).transfer(owner, repayment) returns (bool success) {
                    if (!success) _redirectRepayment(IERC20(loanTerms.currencyToken), owner, repayment);
                } catch {
                    _redirectRepayment(IERC20(loanTerms.currencyToken), owner, repayment);
                }
            }

            /* Call onCollateralLiquidated hook if lender is a contract and implements ILoanRouterHooks interface */
            if (_supportsHooksInterface(owner)) {
                try ILoanRouterHooks(owner).onLoanCollateralLiquidated{gas: HOOK_GAS_LIMIT}(
                    loanTerms, loanTermsHash_, i, principal, interest
                ) {}
                catch (bytes memory reason) {
                    /* Emit hook failed event */
                    emit HookFailed(string(reason));
                }
            }

            /* Emit lender liquidation repaid event */
            emit LenderLiquidationRepaid(loanTermsHash_, owner, i, principal, interest);
        }
    }

    /**
     * @notice Return collateral
     * @param loanTerms Loan terms
     */
    function _returnCollateral(
        LoanTerms calldata loanTerms
    ) internal {
        /* Transfer exit fee from this contract to fee recipient */
        if (loanTerms.feeSpec.exitFee > 0) {
            IERC20(loanTerms.currencyToken).safeTransfer(_getFeeStorage().recipient, loanTerms.feeSpec.exitFee);
        }

        /* Transfer collateral from this contract to borrower */
        IERC721(loanTerms.collateralToken).transferFrom(address(this), msg.sender, loanTerms.collateralTokenId);
    }

    /**
     * @notice Redirect repayment to fee recipient
     * @param token Token
     * @param intendedRecipient Intended recipient address
     * @param amount Amount
     */
    function _redirectRepayment(
        IERC20 token,
        address intendedRecipient,
        uint256 amount
    ) internal {
        /* Get fee recipient */
        address feeRecipient = _getFeeStorage().recipient;

        /* Transfer token to recipient */
        token.safeTransfer(feeRecipient, amount);

        /* Emit transfer failed event */
        emit TransferFailed(address(token), feeRecipient, intendedRecipient, amount);
    }

    /**
     * @notice Check if target supports ILoanRouterHooks interface
     * @param target Target address
     * @return True if target supports hooks interface, otherwise false
     */
    function _supportsHooksInterface(
        address target
    ) internal view returns (bool) {
        /* If target is not a contract */
        if (target.code.length == 0) return false;

        /* Check if target supports ILoanRouterHooks interface */
        (bool success, bytes memory returnData) = ExcessivelySafeCall.excessivelySafeStaticCall(
            target,
            SUPPORTS_INTERFACE_GAS_LIMIT,
            32,
            abi.encodeWithSelector(IERC165.supportsInterface.selector, type(ILoanRouterHooks).interfaceId)
        );

        return success && returnData.length == 32 && uint256(bytes32(returnData)) == 1;
    }

    /**
     * @notice Quote repayment for loan
     * @param loanTerms Loan terms
     * @param timestamp Timestamp
     * @return principalPayment Principal payment
     * @return interestPayment Interest payment
     * @return feesPayment Fees payment
     */
    function _quote(
        LoanTerms calldata loanTerms,
        uint64 timestamp
    ) internal view returns (uint256, uint256, uint256) {
        /* Get loan state */
        bytes32 loanTermsHash_ = _hashLoanTerms(loanTerms);
        LoanState storage loanState_ = _getLoansStorage().loans[loanTermsHash_];

        /* If loan is not active */
        if (loanState_.status != LoanStatus.Active) return (0, 0, 0);

        /* If no repayment is due */
        if (timestamp <= loanState_.repaymentDeadline - loanTerms.repaymentInterval) return (0, 0, 0);

        /* Calculate repayment due */
        (uint256 principalPayment, uint256 interestPayment,,,) = IInterestRateModel(loanTerms.interestRateModel)
            .repayment(loanTerms, loanState_.balance, loanState_.repaymentDeadline, loanState_.maturity, timestamp);

        /* Calculate fees due */
        uint256 feesPayment = loanState_.balance == principalPayment ? loanTerms.feeSpec.exitFee : 0;

        /* Calculate scale factor */
        uint256 scaleFactor_ = 10 ** (18 - IERC20Metadata(loanTerms.currencyToken).decimals());

        return (
            (principalPayment % scaleFactor_ != 0
                    ? principalPayment / scaleFactor_ + 1
                    : principalPayment / scaleFactor_),
            (interestPayment % scaleFactor_ != 0 ? interestPayment / scaleFactor_ + 1 : interestPayment / scaleFactor_),
            feesPayment
        );
    }

    /*------------------------------------------------------------------------*/
    /* Getters */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ILoanRouter
     */
    function depositTimelock() external view returns (address) {
        return _depositTimelock;
    }

    /**
     * @inheritdoc ILoanRouter
     */
    function loanTermsHash(
        LoanTerms calldata loanTerms
    ) external view returns (bytes32) {
        return _hashLoanTerms(loanTerms);
    }

    /**
     * @inheritdoc ILoanRouter
     */
    function loanTokenIds(
        LoanTerms calldata loanTerms
    ) external view returns (uint256[] memory) {
        /* Get loan terms hash */
        bytes32 loanTermsHash_ = _hashLoanTerms(loanTerms);

        /* Get token IDs */
        uint256[] memory tokenIds = new uint256[](loanTerms.trancheSpecs.length);
        for (uint8 i; i < loanTerms.trancheSpecs.length; i++) {
            tokenIds[i] = _tokenId(loanTermsHash_, i);
        }

        return tokenIds;
    }

    /**
     * @inheritdoc ILoanRouter
     */
    function loanState(
        bytes32 loanTermsHash_
    ) public view returns (LoanStatus status, uint64 maturity, uint64 repaymentDeadline, uint256 scaledBalance) {
        LoanState storage loanState_ = _getLoansStorage().loans[loanTermsHash_];

        return (loanState_.status, loanState_.maturity, loanState_.repaymentDeadline, loanState_.balance);
    }

    /**
     * @inheritdoc ILoanRouter
     */
    function loanState(
        uint256 tokenId
    ) external view returns (LoanStatus status, uint64 maturity, uint64 repaymentDeadline, uint256 scaledBalance) {
        LoanReverseLookup storage loanReverseLookup = _getLoansStorage().loanReverseLookups[tokenId];
        return loanState(loanReverseLookup.loanTermsHash);
    }

    /**
     * @inheritdoc ILoanRouter
     */
    function lendingPositionInfo(
        uint256 tokenId
    ) external view returns (bytes32 loanTermsHash_, uint8 trancheIndex) {
        LoanReverseLookup storage loanReverseLookup = _getLoansStorage().loanReverseLookups[tokenId];
        return (loanReverseLookup.loanTermsHash, loanReverseLookup.trancheIndex);
    }

    /*------------------------------------------------------------------------*/
    /* Borrower API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ILoanRouter
     */
    function borrow(
        LoanTerms calldata loanTerms,
        LenderDepositInfo[] calldata lenderDepositInfos
    ) external whenNotPaused scaleFactor(loanTerms.currencyToken) nonReentrant {
        /* Get loan state */
        bytes32 loanTermsHash_ = _hashLoanTerms(loanTerms);
        LoanState storage loanState_ = _getLoansStorage().loans[loanTermsHash_];

        /* Validate caller and loan state */
        if (msg.sender != loanTerms.borrower) revert InvalidCaller();
        if (loanState_.status != LoanStatus.Uninitialized) revert InvalidLoanState();
        if (lenderDepositInfos.length != loanTerms.trancheSpecs.length) revert InvalidLength();

        /* Validate loan terms */
        LoanTermsLogic.validateLoanTerms(loanTerms);

        /* Validate collateral wrapper context */
        if (
            loanTerms.collateralToken == _collateralWrapper
                && ICollateralWrapper(_collateralWrapper).tokenId(loanTerms.collateralWrapperContext)
                    != loanTerms.collateralTokenId
        ) revert InvalidLoanTerms("Collateral Wrapper Context");

        /* Validate lender signatures */
        _validateLenderSignatures(loanTerms, loanState_, lenderDepositInfos);

        /* Calculate principal */
        uint256 principal = _calculatePrincipal(loanTerms);

        /* Update loan state */
        loanState_.status = LoanStatus.Active;
        loanState_.balance = _scale(principal);
        loanState_.maturity = uint64(block.timestamp) + loanTerms.duration;
        loanState_.repaymentDeadline = uint64(block.timestamp) + loanTerms.repaymentInterval;

        /* Transfer collateral token from borrower to this contract */
        IERC721(loanTerms.collateralToken).transferFrom(msg.sender, address(this), loanTerms.collateralTokenId);

        /* Borrow funds */
        _borrowFunds(loanTerms, loanTermsHash_, lenderDepositInfos);

        /* Tokenize lending positions and call onLoanOriginated hooks */
        _tokenizeLendingPositions(loanTerms, loanTermsHash_);

        /* Transfer origination fee to fee recipient */
        if (loanTerms.feeSpec.originationFee > 0) {
            IERC20(loanTerms.currencyToken).safeTransfer(_getFeeStorage().recipient, loanTerms.feeSpec.originationFee);
        }

        /* Transfer principal to borrower */
        IERC20(loanTerms.currencyToken).safeTransfer(msg.sender, principal - loanTerms.feeSpec.originationFee);

        /* Emit loan originated event */
        emit LoanOriginated(
            loanTermsHash_, msg.sender, loanTerms.currencyToken, principal, loanTerms.feeSpec.originationFee
        );
    }

    /**
     * @inheritdoc ILoanRouter
     */
    function quote(
        LoanTerms calldata loanTerms
    ) external view returns (uint256, uint256, uint256) {
        return _quote(loanTerms, uint64(block.timestamp));
    }

    /**
     * @inheritdoc ILoanRouter
     */
    function quote(
        LoanTerms calldata loanTerms,
        uint64 timestamp
    ) external view returns (uint256, uint256, uint256) {
        return _quote(loanTerms, timestamp);
    }

    /**
     * @inheritdoc ILoanRouter
     */
    function repay(
        LoanTerms calldata loanTerms,
        uint256 amount
    ) external whenNotPaused scaleFactor(loanTerms.currencyToken) nonReentrant {
        /* Get loan state */
        bytes32 loanTermsHash_ = _hashLoanTerms(loanTerms);
        LoanState storage loanState_ = _getLoansStorage().loans[loanTermsHash_];

        /* Validate caller and loan state */
        if (msg.sender != loanTerms.borrower) revert InvalidCaller();
        if (loanState_.status != LoanStatus.Active) revert InvalidLoanState();
        if (loanState_.maturity - loanTerms.duration == block.timestamp) revert InvalidLoanState();

        /* Calculate scaled amount */
        uint256 scaledAmount = _scale(amount);

        /* Check if this is a repayment or prepayment */
        bool isRepayment = block.timestamp > loanState_.repaymentDeadline - loanTerms.repaymentInterval;

        uint256 principalPayment;
        uint256 interestPayment;
        uint256[] memory tranchePrincipals = new uint256[](loanTerms.trancheSpecs.length);
        uint256[] memory trancheInterests = new uint256[](loanTerms.trancheSpecs.length);
        uint256 prepayment;

        if (isRepayment) {
            /* Calculate repayment due */
            uint64 servicedIntervals;
            (principalPayment, interestPayment, tranchePrincipals, trancheInterests, servicedIntervals) = IInterestRateModel(
                    loanTerms.interestRateModel
                )
                .repayment(
                    loanTerms,
                    loanState_.balance,
                    loanState_.repaymentDeadline,
                    loanState_.maturity,
                    uint64(block.timestamp)
                );

            /* Validate repayment amount */
            if (scaledAmount < principalPayment + interestPayment) revert InvalidAmount();

            /* Calculate prepayment from excess */
            prepayment =
                Math.min(loanState_.balance - principalPayment, scaledAmount - principalPayment - interestPayment);

            /* Reduce loan balance */
            loanState_.balance -= principalPayment + prepayment;

            /* Update repayment deadline */
            loanState_.repaymentDeadline += servicedIntervals * loanTerms.repaymentInterval;
        } else {
            /* Calculate prepayment */
            prepayment = Math.min(loanState_.balance, scaledAmount);

            /* Reduce loan balance */
            loanState_.balance -= prepayment;
        }

        /* Check if loan is fully repaid */
        bool isFullyRepaid = loanState_.balance == 0;

        /* Validate repayment amount */
        if (
            scaledAmount
                < principalPayment + interestPayment + prepayment
                    + (isFullyRepaid ? _scale(loanTerms.feeSpec.exitFee) : 0)
        ) revert InvalidAmount();

        /* Calculate total repayment (less exit fee) */
        uint256 repayment = _unscale(principalPayment + interestPayment + prepayment, true);

        /* Transfer total repayment amount (and exit fee if any) to this contract */
        IERC20(loanTerms.currencyToken)
            .safeTransferFrom(msg.sender, address(this), repayment + (isFullyRepaid ? loanTerms.feeSpec.exitFee : 0));

        /* If loan is fully repaid, transfer exit fee to fee recipient and return collateral */
        if (isFullyRepaid) {
            /* Update loan status */
            loanState_.status = LoanStatus.Repaid;

            /* Transfer exit fee to fee recipient and return collateral */
            _returnCollateral(loanTerms);
        }

        /* Transfer lender repayments and call onLoanRepayment hooks */
        if (
            _repayLenders(
                    loanTerms, loanTermsHash_, loanState_.balance, trancheInterests, tranchePrincipals, prepayment
                ) > repayment
        ) {
            revert InvalidAmount();
        }

        /* Emit loan repaid event */
        emit LoanRepaid(
            loanTermsHash_,
            msg.sender,
            _unscale(principalPayment),
            _unscale(interestPayment),
            _unscale(prepayment),
            isFullyRepaid ? loanTerms.feeSpec.exitFee : 0,
            isFullyRepaid
        );
    }

    /*------------------------------------------------------------------------*/
    /* Lender API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ILoanRouter
     */
    function increaseNonce(
        LoanTerms calldata loanTerms
    ) external nonReentrant {
        /* Get loan state */
        bytes32 loanTermsHash_ = _hashLoanTerms(loanTerms);
        LoanState storage loanState_ = _getLoansStorage().loans[loanTermsHash_];

        /* Validate loan state is uninitialized */
        if (loanState_.status != LoanStatus.Uninitialized) revert InvalidLoanState();

        /* Increase nonce */
        loanState_.nonces[msg.sender]++;

        /* Emit nonce increased event */
        emit NonceIncreased(loanTermsHash_, msg.sender, loanState_.nonces[msg.sender]);
    }

    /*------------------------------------------------------------------------*/
    /* Liquidator API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ILoanRouter
     */
    function liquidate(
        LoanTerms calldata loanTerms
    ) external nonReentrant {
        /* Get loan state */
        bytes32 loanTermsHash_ = _hashLoanTerms(loanTerms);
        LoanState storage loanState_ = _getLoansStorage().loans[loanTermsHash_];

        /* Check if loan is active */
        if (loanState_.status != LoanStatus.Active) revert InvalidLoanState();

        /* Check if loan is past grace period */
        if (block.timestamp <= loanState_.repaymentDeadline + loanTerms.gracePeriodDuration) {
            revert InvalidLoanState();
        }

        /* Update loan status */
        loanState_.status = LoanStatus.Liquidated;

        /* Approve collateral for transfer to liquidator */
        IERC721(loanTerms.collateralToken).approve(_collateralLiquidator, loanTerms.collateralTokenId);

        /* Liquidate loan */
        ICollateralLiquidator(_collateralLiquidator)
            .liquidate(
                loanTerms.currencyToken,
                loanTerms.collateralToken,
                loanTerms.collateralTokenId,
                loanTerms.collateralWrapperContext,
                abi.encode(loanTerms)
            );

        /* Call onLoanLiquidated hook for each tranche */
        for (uint8 i; i < loanTerms.trancheSpecs.length; i++) {
            /* Get token owner */
            address owner = _ownerOf(_tokenId(loanTermsHash_, i));

            /* Call onLoanLiquidated hook if lender is a contract and implements ILoanRouterHooks interface */
            if (_supportsHooksInterface(owner)) {
                try ILoanRouterHooks(owner).onLoanLiquidated{gas: HOOK_GAS_LIMIT}(loanTerms, loanTermsHash_, i) {}
                catch (bytes memory reason) {
                    /* Emit hook failed event */
                    emit HookFailed(string(reason));
                }
            }
        }

        /* Emit loan liquidated event */
        emit LoanLiquidated(loanTermsHash_);
    }

    /**
     * @inheritdoc ILoanRouter
     */
    function onCollateralLiquidated(
        bytes calldata encodedLoanTerms,
        uint256 proceeds
    ) external nonReentrant {
        /* Check if caller is collateral liquidator */
        if (msg.sender != _collateralLiquidator) revert InvalidCaller();

        /* Decode loan terms */
        LoanTerms memory loanTerms = abi.decode(encodedLoanTerms, (LoanTerms));

        _onCollateralLiquidated(loanTerms, proceeds);
    }

    /**
     * @notice onCollateralLiquidated() implementation with ABI-decoded loan terms
     */
    function _onCollateralLiquidated(
        LoanTerms memory loanTerms,
        uint256 proceeds
    ) internal scaleFactor(loanTerms.currencyToken) {
        /* Get loan state */
        bytes32 loanTermsHash_ = _hashLoanTerms(loanTerms);
        LoanState storage loanState_ = _getLoansStorage().loans[loanTermsHash_];

        /* Check loan is liquidated */
        if (loanState_.status != LoanStatus.Liquidated) revert InvalidLoanState();

        /* Calculate scaled proceeds */
        uint256 scaledProceeds = _scale(proceeds);

        /* Compute liquidation fee */
        uint256 liquidationFee = Math.mulDiv(scaledProceeds, _getFeeStorage().liquidationFeeRate, BASIS_POINTS_SCALE);

        /* Compute tranche principals (entire remaining balance) */
        (,, uint256[] memory tranchePrincipals,,) = IInterestRateModel(loanTerms.interestRateModel)
            .repayment(
                loanTerms, loanState_.balance, loanState_.repaymentDeadline, loanState_.maturity, loanState_.maturity
            );

        /* Compute tranche interests (only the defaulted intervals and grace period interest) */
        /* There may be overlap of defaulted interval interest and grace period interest */
        (,,, uint256[] memory trancheInterests,) = IInterestRateModel(loanTerms.interestRateModel)
            .repayment(
                loanTerms,
                loanState_.balance,
                loanState_.repaymentDeadline,
                loanState_.maturity,
                uint64(block.timestamp)
            );

        /* Remaining proceeds after liquidation fee */
        uint256 remainingProceeds = scaledProceeds - liquidationFee;

        /* Distribute remaining proceeds to tranche principals */
        for (uint8 i; i < loanTerms.trancheSpecs.length; i++) {
            tranchePrincipals[i] = Math.min(tranchePrincipals[i], remainingProceeds);
            remainingProceeds -= tranchePrincipals[i];
        }

        /* Distribute remaining proceeds to tranche interests */
        for (uint8 i; i < loanTerms.trancheSpecs.length; i++) {
            trancheInterests[i] = Math.min(trancheInterests[i], remainingProceeds);
            remainingProceeds -= trancheInterests[i];
        }

        /* Update loan status */
        loanState_.balance = 0;
        loanState_.status = LoanStatus.CollateralLiquidated;

        /* Transfer lender liquidation repayments and call onLoanCollateralLiquidated hooks */
        _repayLendersLiquidation(loanTerms, loanTermsHash_, trancheInterests, tranchePrincipals);

        /* Unscale liquidation fee and surplus */
        liquidationFee = _unscale(liquidationFee);
        remainingProceeds = _unscale(remainingProceeds);

        /* Transfer liquidation fee and surplus to fee recipient */
        if (liquidationFee + remainingProceeds > 0) {
            IERC20(loanTerms.currencyToken).safeTransfer(_getFeeStorage().recipient, liquidationFee + remainingProceeds);
        }

        /* Emit loan collateral liquidated event */
        emit LoanCollateralLiquidated(
            loanTermsHash_, proceeds - liquidationFee - remainingProceeds, liquidationFee, remainingProceeds
        );
    }

    /*------------------------------------------------------------------------*/
    /* Permissioned API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ILoanRouter
     */
    function pause() external onlyRole(PAUSE_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @inheritdoc ILoanRouter
     */
    function unpause() external onlyRole(PAUSE_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @inheritdoc ILoanRouter
     */
    function setFeeRecipient(
        address recipient
    ) external nonZeroAddress(recipient) onlyRole(DEFAULT_ADMIN_ROLE) {
        _getFeeStorage().recipient = recipient;

        emit FeeRecipientSet(recipient);
    }

    /**
     * @inheritdoc ILoanRouter
     */
    function setLiquidationFeeRate(
        uint256 liquidationFeeRate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _getFeeStorage().liquidationFeeRate = liquidationFeeRate;

        /* Emit liquidation fee rate set event */
        emit LiquidationFeeRateSet(liquidationFeeRate);
    }

    /*------------------------------------------------------------------------*/
    /* ERC165 */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        virtual
        override(AccessControlUpgradeable, ERC165Upgradeable, ERC721EnumerableUpgradeable)
        returns (bool)
    {
        return interfaceId == type(ILoanRouter).interfaceId || interfaceId == type(IERC721).interfaceId
            || interfaceId == type(IERC5267).interfaceId
            || interfaceId == type(ICollateralLiquidationReceiver).interfaceId || super.supportsInterface(interfaceId);
    }
}
