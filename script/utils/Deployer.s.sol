// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.29;

import {stdJson} from "forge-std/StdJson.sol";
import {console2 as console} from "forge-std/console2.sol";

import {BaseScript} from "./Base.s.sol";

contract Deployer is BaseScript {
    /*--------------------------------------------------------------------------*/
    /* Errors                                                                   */
    /*--------------------------------------------------------------------------*/

    error MissingDependency();

    error AlreadyDeployed();

    error InvalidParameter();

    /*--------------------------------------------------------------------------*/
    /* Structures                                                               */
    /*--------------------------------------------------------------------------*/

    struct Deployment {
        address loanRouter;
        address depositTimelock;
        address simpleInterestRateModel;
        address amortizedInterestRateModel;
        address bundleCollateralWrapper;
        address externalCollateralLiquidator;
    }

    /*--------------------------------------------------------------------------*/
    /* State Variables                                                          */
    /*--------------------------------------------------------------------------*/

    Deployment internal _deployment;

    /*--------------------------------------------------------------------------*/
    /* Modifier                                                                 */
    /*--------------------------------------------------------------------------*/

    /**
     * @dev Add useDeployment modifier to deployment script run() function to
     *      deserialize deployments json and make properties available to read,
     *      write and modify. Changes are re-serialized at end of script.
     */
    modifier useDeployment() {
        console.log("Using deployment\n");
        console.log("Network: %s\n", _chainIdToNetwork[block.chainid]);

        _deserialize();

        _;

        _serialize();

        console.log("Using deployment completed\n");
    }

    /*--------------------------------------------------------------------------*/
    /* Internal Helpers                                                         */
    /*--------------------------------------------------------------------------*/

    /**
     * @notice Internal helper to get deployment file path for current network
     *
     * @return Path
     */
    function _getJsonFilePath() internal view returns (string memory) {
        return string(abi.encodePacked(vm.projectRoot(), "/deployments/", _chainIdToNetwork[block.chainid], ".json"));
    }

    /**
     * @notice Internal helper to read and return json string
     *
     * @return Json string
     */
    function _getJson() internal view returns (string memory) {
        string memory path = _getJsonFilePath();

        string memory json = "{}";

        /// forge-lint: disable-next-line(unsafe-cheatcode)
        try vm.readFile(path) returns (string memory _json) {
            json = _json;
        } catch {
            console.log("No json file found at: %s\n", path);
        }

        return json;
    }

    /*--------------------------------------------------------------------------*/
    /* API                                                                      */
    /*--------------------------------------------------------------------------*/

    /**
     * @notice Serialize the _deployment storage struct
     */
    function _serialize() internal {
        /* Initialize json string */
        string memory json = "";

        json = stdJson.serialize("", "loanRouter", _deployment.loanRouter);
        json = stdJson.serialize("", "depositTimelock", _deployment.depositTimelock);
        json = stdJson.serialize("", "simpleInterestRateModel", _deployment.simpleInterestRateModel);
        json = stdJson.serialize("", "amortizedInterestRateModel", _deployment.amortizedInterestRateModel);
        json = stdJson.serialize("", "bundleCollateralWrapper", _deployment.bundleCollateralWrapper);
        json = stdJson.serialize("", "externalCollateralLiquidator", _deployment.externalCollateralLiquidator);

        console.log("Writing json to file: %s\n", json);
        vm.writeJson(json, _getJsonFilePath());
    }

    /**
     * @notice Deserialize the deployment json
     *
     * @dev Deserialization loads the json into the _deployment struct
     */
    function _deserialize() internal {
        string memory json = _getJson();

        /* Deserialize loanRouter */
        try vm.parseJsonAddress(json, ".loanRouter") returns (address instance) {
            _deployment.loanRouter = instance;
        } catch {
            console.log("Could not parse loanRouter");
        }

        /* Deserialize depositTimelock */
        try vm.parseJsonAddress(json, ".depositTimelock") returns (address instance) {
            _deployment.depositTimelock = instance;
        } catch {
            console.log("Could not parse depositTimelock");
        }

        /* Deserialize simpleInterestRateModel */
        try vm.parseJsonAddress(json, ".simpleInterestRateModel") returns (address instance) {
            _deployment.simpleInterestRateModel = instance;
        } catch {
            console.log("Could not parse simpleInterestRateModel");
        }

        /* Deserialize amortizedInterestRateModel */
        try vm.parseJsonAddress(json, ".amortizedInterestRateModel") returns (address instance) {
            _deployment.amortizedInterestRateModel = instance;
        } catch {
            console.log("Could not parse amortizedInterestRateModel");
        }

        /* Deserialize bundleCollateralWrapper */
        try vm.parseJsonAddress(json, ".bundleCollateralWrapper") returns (address instance) {
            _deployment.bundleCollateralWrapper = instance;
        } catch {
            console.log("Could not parse bundleCollateralWrapper");
        }

        /* Deserialize externalCollateralLiquidator */
        try vm.parseJsonAddress(json, ".externalCollateralLiquidator") returns (address instance) {
            _deployment.externalCollateralLiquidator = instance;
        } catch {
            console.log("Could not parse externalCollateralLiquidator");
        }
    }
}
