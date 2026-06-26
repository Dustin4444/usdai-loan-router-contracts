// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {ReserveAccount} from "src/ReserveAccount.sol";

import {Deployer} from "./utils/Deployer.s.sol";

interface ICreateX {
    function deployCreate(
        bytes memory initCode
    ) external payable returns (address newContract);
}

contract DeployReserveAccountCalldata is Deployer {
    ICreateX internal constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    function run(
        address borrower,
        address currencyToken,
        uint256 reservesRequired
    ) public broadcast useDeployment {
        if (_deployment.reserveAccountBeacon == address(0x0)) revert MissingDependency();

        bytes memory reserveAccountProxyCreateCalldata = abi.encodeWithSelector(
            ICreateX.deployCreate.selector,
            abi.encodePacked(
                type(BeaconProxy).creationCode,
                abi.encode(
                    address(_deployment.reserveAccountBeacon),
                    abi.encodeWithSelector(
                        ReserveAccount.initialize.selector, borrower, currencyToken, reservesRequired
                    )
                )
            )
        );

        console.log("");
        console.log("from deployer multisig");
        console.log("target", address(CREATEX));
        console.log("Reserve Account proxy calldata");
        console.logBytes(reserveAccountProxyCreateCalldata);
    }
}
