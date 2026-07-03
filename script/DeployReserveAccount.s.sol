// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import {ReserveAccountFactory} from "src/ReserveAccountFactory.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract DeployReserveAccount is Deployer {
    function run(
        address borrower,
        address currencyToken,
        uint256 reservesRequired,
        bytes32 salt
    ) public broadcast useDeployment returns (address) {
        if (_deployment.reserveAccountFactory == address(0x0)) revert MissingDependency();

        // Create reserve account through the factory
        address reserveAccount = ReserveAccountFactory(_deployment.reserveAccountFactory)
            .create(borrower, currencyToken, reservesRequired, salt);
        console.log("ReserveAccount", reserveAccount);

        return reserveAccount;
    }
}
