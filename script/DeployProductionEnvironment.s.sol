// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {DepositTimelock} from "src/DepositTimelock.sol";
import {EscrowTimelock} from "src/EscrowTimelock.sol";
import {CollateralTimelock} from "src/CollateralTimelock.sol";
import {LoanRouterV2} from "src/LoanRouterV2.sol";
import {ReserveAccount} from "src/ReserveAccount.sol";
import {SimpleInterestRateModel} from "src/rates/SimpleInterestRateModel.sol";
import {AmortizedInterestRateModel} from "src/rates/AmortizedInterestRateModel.sol";
import {AbsoluteFeeModel} from "src/fees/AbsoluteFeeModel.sol";
import {RatioFeeModel} from "src/fees/RatioFeeModel.sol";

import {Deployer} from "./utils/Deployer.s.sol";

interface ICreateX {
    function computeCreate3Address(
        bytes32 salt
    ) external view returns (address computedAddress);
    function deployCreate3(
        bytes32 salt,
        bytes memory initCode
    ) external payable returns (address newContract);
}

contract DeployProductionEnvironment is Deployer {
    ICreateX internal constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    address internal constant USDAI_ADDRESS = address(0x0A1a1A107E45b7Ced86833863f482BC5f4ed82EF);
    address internal constant STAKED_USDAI_ADDRESS = address(0x0B2b2B2076d95dda7817e785989fE353fe955ef9);
    address internal constant LOAN_ROUTER_V1_ADDRESS = address(0x0C2ED170F2bB1DF1a44292Ad621B577b3C9597D1);

    address internal constant COLLATERAL_TIMELOCK_ADDRESS = address(0x1C710CC0f5562752E88f5A5cC36fA72E73DBEa45);
    bytes32 internal constant COLLATERAL_TIMELOCK_SALT =
        0x783b08aa21de056717173f72e04be0e91328a07b00a3dcd0f94c0e0a03afd0c5;

    address internal constant DEPOSIT_TIMELOCK_ADDRESS = address(0x1D710CC0c435bA6e27ABC82A51DFBcA17C41FE3C);
    bytes32 internal constant DEPOSIT_TIMELOCK_SALT =
        0x783b08aa21de056717173f72e04be0e91328a07b000243f934289e7501de6afb;

    address internal constant ESCROW_TIMELOCK_ADDRESS = address(0x1E710CC0b64E1D7572d35E43AD261587789B6438);
    bytes32 internal constant ESCROW_TIMELOCK_SALT = 0x783b08aa21de056717173f72e04be0e91328a07b008cafd757bdf69600ff830f;

    address internal constant LOAN_ROUTER_V2_ADDRESS = address(0x1C2ED170de32846316784c4fd58A5e3C7563E12f);
    bytes32 internal constant LOAN_ROUTER_V2_SALT = 0x783b08aa21de056717173f72e04be0e91328a07b003eda62a188da7a03594529;

    address internal constant RESERVE_ACCOUNT_BEACON_ADDRESS = address(0x12E5E200a56A24a1CA2aF175F66574c623ADe6B1);
    bytes32 internal constant RESERVE_ACCOUNT_BEACON_SALT =
        0x783b08aa21de056717173f72e04be0e91328a07b0050cb6e0cd381e301acefcc;

    function run(
        address deployer,
        address admin,
        address feeRecipient,
        address escrowAdmin
    )
        public
        broadcast
        useDeployment
        returns (address, address, address, address, address, address, address, address, address)
    {
        // Deploy CollateralTimelock implementation
        CollateralTimelock collateralTimelockImpl = new CollateralTimelock();
        console.log("CollateralTimelock implementation", address(collateralTimelockImpl));

        // Deploy DepositTimelock implementation
        DepositTimelock depositTimelockImpl = new DepositTimelock();
        console.log("DepositTimelock implementation", address(depositTimelockImpl));

        // Deploy EscrowTimelock implementation
        EscrowTimelock escrowTimelockImpl = new EscrowTimelock(USDAI_ADDRESS, STAKED_USDAI_ADDRESS, escrowAdmin);
        console.log("EscrowTimelock implementation", address(escrowTimelockImpl));

        // Deploy SimpleInterestRateModel
        SimpleInterestRateModel simpleInterestRateModel = new SimpleInterestRateModel();
        console.log("SimpleInterestRateModel", address(simpleInterestRateModel));

        // Deploy AmortizedInterestRateModel
        AmortizedInterestRateModel amortizedInterestRateModel = new AmortizedInterestRateModel();
        console.log("AmortizedInterestRateModel", address(amortizedInterestRateModel));

        // Deploy AbsoluteFeeModel
        AbsoluteFeeModel absoluteFeeModel = new AbsoluteFeeModel();
        console.log("AbsoluteFeeModel", address(absoluteFeeModel));

        // Deploy RatioFeeModel
        RatioFeeModel ratioFeeModel = new RatioFeeModel();
        console.log("RatioFeeModel", address(ratioFeeModel));

        // Deploy LoanRouterV2 implementation
        LoanRouterV2 loanRouterImpl = new LoanRouterV2(
            feeRecipient,
            COLLATERAL_TIMELOCK_ADDRESS,
            DEPOSIT_TIMELOCK_ADDRESS,
            ESCROW_TIMELOCK_ADDRESS,
            LOAN_ROUTER_V1_ADDRESS
        );
        console.log("LoanRouterV2 implementation", address(loanRouterImpl));

        // Deploy ReserveAccount implementation
        ReserveAccount reserveAccountImpl = new ReserveAccount(admin, LOAN_ROUTER_V2_ADDRESS);
        console.log("ReserveAccount implementation", address(reserveAccountImpl));

        // Prepare Create3 Calldata for Collateral Timelock Proxy
        if (
            CREATEX.computeCreate3Address(keccak256(abi.encode(deployer, COLLATERAL_TIMELOCK_SALT)))
                != COLLATERAL_TIMELOCK_ADDRESS
        ) {
            revert InvalidParameter();
        }
        bytes memory collateralTimelockProxyCreate3Calldata = abi.encodeWithSelector(
            ICreateX.deployCreate3.selector,
            COLLATERAL_TIMELOCK_SALT,
            abi.encodePacked(
                type(TransparentUpgradeableProxy).creationCode,
                abi.encode(
                    address(collateralTimelockImpl),
                    deployer,
                    abi.encodeWithSelector(CollateralTimelock.initialize.selector, admin)
                )
            )
        );

        // Prepare Create3 Calldata for Deposit Timelock Proxy
        if (
            CREATEX.computeCreate3Address(keccak256(abi.encode(deployer, DEPOSIT_TIMELOCK_SALT)))
                != DEPOSIT_TIMELOCK_ADDRESS
        ) {
            revert InvalidParameter();
        }
        bytes memory depositTimelockProxyCreate3Calldata = abi.encodeWithSelector(
            ICreateX.deployCreate3.selector,
            DEPOSIT_TIMELOCK_SALT,
            abi.encodePacked(
                type(TransparentUpgradeableProxy).creationCode,
                abi.encode(
                    address(depositTimelockImpl),
                    deployer,
                    abi.encodeWithSelector(DepositTimelock.initialize.selector, admin)
                )
            )
        );

        // Prepare Create3 Calldata for Escrow Timelock Proxy
        if (
            CREATEX.computeCreate3Address(keccak256(abi.encode(deployer, ESCROW_TIMELOCK_SALT)))
                != ESCROW_TIMELOCK_ADDRESS
        ) {
            revert InvalidParameter();
        }
        bytes memory escrowTimelockProxyCreate3Calldata = abi.encodeWithSelector(
            ICreateX.deployCreate3.selector,
            ESCROW_TIMELOCK_SALT,
            abi.encodePacked(
                type(TransparentUpgradeableProxy).creationCode,
                abi.encode(
                    address(escrowTimelockImpl),
                    deployer,
                    abi.encodeWithSelector(EscrowTimelock.initialize.selector, admin)
                )
            )
        );

        // Prepare Create3 Calldata for Loan Router Proxy
        if (
            CREATEX.computeCreate3Address(keccak256(abi.encode(deployer, LOAN_ROUTER_V2_SALT)))
                != LOAN_ROUTER_V2_ADDRESS
        ) {
            revert InvalidParameter();
        }
        bytes memory loanRouterProxyCreate3Calldata = abi.encodeWithSelector(
            ICreateX.deployCreate3.selector,
            LOAN_ROUTER_V2_SALT,
            abi.encodePacked(
                type(TransparentUpgradeableProxy).creationCode,
                abi.encode(
                    address(loanRouterImpl), deployer, abi.encodeWithSelector(LoanRouterV2.initialize.selector, admin)
                )
            )
        );

        // Prepare Create3 Calldata for Reserve Account Beacon
        if (
            CREATEX.computeCreate3Address(keccak256(abi.encode(deployer, RESERVE_ACCOUNT_BEACON_SALT)))
                != RESERVE_ACCOUNT_BEACON_ADDRESS
        ) {
            revert("Invalid salt");
        }
        bytes memory reserveAccountBeaconCreate3Calldata = abi.encodeWithSelector(
            ICreateX.deployCreate3.selector,
            RESERVE_ACCOUNT_BEACON_SALT,
            abi.encodePacked(type(UpgradeableBeacon).creationCode, abi.encode(address(reserveAccountImpl), deployer))
        );

        // Print calldata
        console.log("");
        console.log("from deployer multisig");
        console.log("target", address(CREATEX));
        console.log("Collateral Timelock proxy calldata");
        console.logBytes(collateralTimelockProxyCreate3Calldata);
        console.log("Deposit Timelock proxy calldata");
        console.logBytes(depositTimelockProxyCreate3Calldata);
        console.log("Escrow Timelock proxy calldata");
        console.logBytes(escrowTimelockProxyCreate3Calldata);
        console.log("Loan Router proxy calldata");
        console.logBytes(loanRouterProxyCreate3Calldata);
        console.log("Reserve Account Beacon calldata");
        console.logBytes(reserveAccountBeaconCreate3Calldata);

        // Update deployment
        _deployment.collateralTimelock = COLLATERAL_TIMELOCK_ADDRESS;
        _deployment.depositTimelock = DEPOSIT_TIMELOCK_ADDRESS;
        _deployment.escrowTimelock = ESCROW_TIMELOCK_ADDRESS;
        _deployment.loanRouterV2 = LOAN_ROUTER_V2_ADDRESS;
        _deployment.simpleInterestRateModel = address(simpleInterestRateModel);
        _deployment.amortizedInterestRateModel = address(amortizedInterestRateModel);
        _deployment.absoluteFeeModel = address(absoluteFeeModel);
        _deployment.ratioFeeModel = address(ratioFeeModel);
        _deployment.reserveAccountBeacon = RESERVE_ACCOUNT_BEACON_ADDRESS;

        return (
            COLLATERAL_TIMELOCK_ADDRESS,
            DEPOSIT_TIMELOCK_ADDRESS,
            ESCROW_TIMELOCK_ADDRESS,
            LOAN_ROUTER_V2_ADDRESS,
            address(simpleInterestRateModel),
            address(amortizedInterestRateModel),
            address(absoluteFeeModel),
            address(ratioFeeModel),
            RESERVE_ACCOUNT_BEACON_ADDRESS
        );
    }
}
