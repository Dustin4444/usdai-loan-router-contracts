// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {DepositTimelock} from "src/DepositTimelock.sol";
import {EscrowTimelock} from "src/EscrowTimelock.sol";
import {LoanRouter} from "src/LoanRouter.sol";

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
    address internal constant ESCROW_ADMIN_ADDRESS = address(0x0000000000000000000000000000000000000000);

    address internal constant DEPOSIT_TIMELOCK_ADDRESS = address(0x0D710CC05f34d2eaD9fbA3c78d53d76a0623c9F8);
    address internal constant ESCROW_TIMELOCK_ADDRESS = address(0x0000000000000000000000000000000000000000);
    address internal constant LOAN_ROUTER_ADDRESS = address(0x0C2ED170F2bB1DF1a44292Ad621B577b3C9597D1);
    bytes32 internal constant DEPOSIT_TIMELOCK_SALT =
        0x783b08aa21de056717173f72e04be0e91328a07b002c641951ebd07101f521d4;
    bytes32 internal constant ESCROW_TIMELOCK_SALT = 0x0000000000000000000000000000000000000000000000000000000000000000;
    bytes32 internal constant LOAN_ROUTER_SALT = 0x783b08aa21de056717173f72e04be0e91328a07b0065ee1b84aaac8c00f59d63;

    function run(
        address deployer,
        address collateralLiquidator,
        address collateralWrapper,
        address admin,
        uint256 liquidationFeeRate
    ) public broadcast useDeployment returns (address, address, address) {
        // Deploy DepositTimelock implementation
        DepositTimelock depositTimelockImpl = new DepositTimelock();
        console.log("DepositTimelock implementation", address(depositTimelockImpl));

        // Deploy EscrowTimelock implementation
        EscrowTimelock escrowTimelockImpl =
            new EscrowTimelock(USDAI_ADDRESS, STAKED_USDAI_ADDRESS, ESCROW_ADMIN_ADDRESS);
        console.log("EscrowTimelock implementation", address(escrowTimelockImpl));

        // Deploy LoanRouter implementation
        LoanRouter loanRouterImpl = new LoanRouter(DEPOSIT_TIMELOCK_ADDRESS, collateralLiquidator, collateralWrapper);
        console.log("LoanRouter implementation", address(loanRouterImpl));

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
        if (CREATEX.computeCreate3Address(keccak256(abi.encode(deployer, LOAN_ROUTER_SALT))) != LOAN_ROUTER_ADDRESS) {
            revert InvalidParameter();
        }
        bytes memory loanRouterProxyCreate3Calldata = abi.encodeWithSelector(
            ICreateX.deployCreate3.selector,
            LOAN_ROUTER_SALT,
            abi.encodePacked(
                type(TransparentUpgradeableProxy).creationCode,
                abi.encode(
                    address(loanRouterImpl),
                    deployer,
                    abi.encodeWithSelector(LoanRouter.initialize.selector, admin, admin, liquidationFeeRate)
                )
            )
        );

        // Print calldata
        console.log("");
        console.log("from deployer multisig");
        console.log("target", address(CREATEX));
        console.log("Deposit Timelock proxy calldata");
        console.logBytes(depositTimelockProxyCreate3Calldata);
        console.log("Escrow Timelock proxy calldata");
        console.logBytes(escrowTimelockProxyCreate3Calldata);
        console.log("Loan Router proxy calldata");
        console.logBytes(loanRouterProxyCreate3Calldata);

        // Update deployment
        _deployment.depositTimelock = DEPOSIT_TIMELOCK_ADDRESS;
        _deployment.escrowTimelock = ESCROW_TIMELOCK_ADDRESS;
        _deployment.loanRouter = LOAN_ROUTER_ADDRESS;

        return (DEPOSIT_TIMELOCK_ADDRESS, ESCROW_TIMELOCK_ADDRESS, LOAN_ROUTER_ADDRESS);
    }
}
