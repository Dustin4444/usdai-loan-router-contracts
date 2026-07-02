// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ReserveAccountFactory} from "src/ReserveAccountFactory.sol";

import {Deployer} from "./utils/Deployer.s.sol";
import {ICreateX} from "./DeployProductionEnvironment.s.sol";

contract DeployReserveAccountFactory is Deployer {
    ICreateX internal constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    address internal constant RESERVE_ACCOUNT_FACTORY_ADDRESS = address(0);
    bytes32 internal constant RESERVE_ACCOUNT_FACTORY_SALT = bytes32(0);

    function run(
        address deployer,
        address admin
    ) public broadcast useDeployment returns (address) {
        if (_deployment.reserveAccountBeacon == address(0x0)) revert MissingDependency();

        // Deploy ReserveAccountFactory implementation
        ReserveAccountFactory reserveAccountFactoryImpl = new ReserveAccountFactory(_deployment.reserveAccountBeacon);
        console.log("ReserveAccountFactory implementation", address(reserveAccountFactoryImpl));

        // Prepare Create3 calldata for the factory proxy
        if (
            CREATEX.computeCreate3Address(keccak256(abi.encode(deployer, RESERVE_ACCOUNT_FACTORY_SALT)))
                != RESERVE_ACCOUNT_FACTORY_ADDRESS
        ) {
            revert InvalidParameter();
        }
        bytes memory factoryProxyCreate3Calldata = abi.encodeWithSelector(
            ICreateX.deployCreate3.selector,
            RESERVE_ACCOUNT_FACTORY_SALT,
            abi.encodePacked(
                type(TransparentUpgradeableProxy).creationCode,
                abi.encode(
                    address(reserveAccountFactoryImpl),
                    deployer,
                    abi.encodeWithSelector(ReserveAccountFactory.initialize.selector, admin)
                )
            )
        );

        // Print calldata
        console.log("");
        console.log("from deployer multisig");
        console.log("target", address(CREATEX));
        console.log("Reserve Account Factory proxy calldata");
        console.logBytes(factoryProxyCreate3Calldata);

        // Update deployment
        _deployment.reserveAccountFactory = RESERVE_ACCOUNT_FACTORY_ADDRESS;

        return RESERVE_ACCOUNT_FACTORY_ADDRESS;
    }
}
