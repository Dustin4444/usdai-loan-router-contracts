#!/usr/bin/env bash

set -e

declare -A SCRIPTS=(
    ["deploy-collateral-timelock"]="script/DeployCollateralTimelock.s.sol:DeployCollateralTimelock"
    ["deploy-deposit-timelock"]="script/DeployDepositTimelock.s.sol:DeployDepositTimelock"
    ["deploy-escrow-timelock"]="script/DeployEscrowTimelock.s.sol:DeployEscrowTimelock"
    ["deploy-simple-interest-rate-model"]="script/DeploySimpleInterestRateModel.s.sol:DeploySimpleInterestRateModel"
    ["deploy-amortized-interest-rate-model"]="script/DeployAmortizedInterestRateModel.s.sol:DeployAmortizedInterestRateModel"
    ["deploy-absolute-fee-model"]="script/DeployAbsoluteFeeModel.s.sol:DeployAbsoluteFeeModel"
    ["deploy-ratio-fee-model"]="script/DeployRatioFeeModel.s.sol:DeployRatioFeeModel"
    ["deploy-reserve-account-beacon"]="script/DeployReserveAccountBeacon.s.sol:DeployReserveAccountBeacon"
    ["deploy-reserve-account"]="script/DeployReserveAccount.s.sol:DeployReserveAccount"
    ["deploy-reserve-account-calldata"]="script/DeployReserveAccountCalldata.s.sol:DeployReserveAccountCalldata"
    ["deploy-loan-router-v2"]="script/DeployLoanRouterV2.s.sol:DeployLoanRouterV2"
    ["upgrade-collateral-timelock"]="script/UpgradeCollateralTimelock.s.sol:UpgradeCollateralTimelock"
    ["upgrade-deposit-timelock"]="script/UpgradeDepositTimelock.s.sol:UpgradeDepositTimelock"
    ["upgrade-escrow-timelock"]="script/UpgradeEscrowTimelock.s.sol:UpgradeEscrowTimelock"
    ["upgrade-loan-router-v2"]="script/UpgradeLoanRouterV2.s.sol:UpgradeLoanRouterV2"
    ["upgrade-reserve-account-beacon"]="script/UpgradeReserveAccountBeacon.s.sol:UpgradeReserveAccountBeacon"
    ["deploy-production-environment"]="script/DeployProductionEnvironment.s.sol:DeployProductionEnvironment"
    ["show"]="script/Show.s.sol:Show"
)

usage() {
    echo "Usage: $0 <command> [arguments...]"
    echo ""
    echo "Commands:"
    echo "  deploy-collateral-timelock <deployer> <admin>"
    echo "  deploy-deposit-timelock <deployer> <admin>"
    echo "  deploy-escrow-timelock <deployer> <admin> <deposit token> <depositor> <escrow admin>"
    echo "  deploy-simple-interest-rate-model"
    echo "  deploy-amortized-interest-rate-model"
    echo "  deploy-absolute-fee-model"
    echo "  deploy-ratio-fee-model"
    echo "  deploy-reserve-account-beacon <admin>"
    echo "  deploy-reserve-account <borrower> <currency token> <reserves required>"
    echo "  deploy-reserve-account-calldata <borrower> <currency token> <reserves required>"
    echo "  deploy-loan-router-v2 <deployer> <admin> <fee recipient> <loan router v1>"
    echo ""
    echo "  upgrade-collateral-timelock"
    echo "  upgrade-deposit-timelock"
    echo "  upgrade-escrow-timelock <deposit token> <escrow depositor> <escrow admin>"
    echo "  upgrade-loan-router-v2 <fee recipient> <loan router v1>"
    echo "  upgrade-reserve-account-beacon"
    echo ""
    echo "  deploy-production-environment <deployer> <admin> <fee recipient> <escrow admin>"
    echo ""
    echo "  show"
}

# Check argument count
if [ "$#" -lt 1 ]; then
    usage
    exit 0
fi

# Check for NETWORK env var
if [[ -z "$NETWORK" ]]; then
    echo -e "Error: NETWORK env var missing.\n"
    usage
    exit 1
fi

# Check for <NETWORK>_RPC_URL env var
RPC_URL_VAR=${NETWORK^^}_RPC_URL
RPC_URL=${!RPC_URL_VAR}
if [[ -z "$RPC_URL" ]]; then
    echo -e "Error: $RPC_URL env var missing.\n"
    usage
    exit 1
fi

# Look up script
SCRIPT=${SCRIPTS[$1]}
if [[ -z "$SCRIPT" ]]; then
    echo -e "Error: unknown command \"$1\"\n"
    usage
    exit 1
fi

# Look up script signature
SIGNATURE=$(forge inspect --no-cache --contracts script "$SCRIPT" mi --json | grep -o "run(.*)")

echo -e "Running on $NETWORK\n"

if [[ ! -z "$LEDGER_DERIVATION_PATH" ]]; then
    forge script --rpc-url "$RPC_URL" --ledger --hd-paths "$LEDGER_DERIVATION_PATH" --sender "$LEDGER_ADDRESS" --broadcast -vvvv "$SCRIPT" --sig "$SIGNATURE" "${@:2}"
elif [[ ! -z "$PRIVATE_KEY" ]]; then
    forge script --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --sender "$(cast wallet address "$PRIVATE_KEY")" --broadcast -vvvv "$SCRIPT" --sig "$SIGNATURE" "${@:2}"
else
    forge script --rpc-url "$RPC_URL" -vvvv "$SCRIPT" --sig "$SIGNATURE" "${@:2}"
fi
