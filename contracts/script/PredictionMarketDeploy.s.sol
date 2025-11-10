// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PredictionMarket.sol";

/// @title PredictionMarketDeploy
/// @notice Foundry script used to deploy the PredictionMarket contract with environment-configured parameters.
contract PredictionMarketDeploy is Script {
    /// @notice Deploys the PredictionMarket contract using environment variable configuration.
    function run() external returns (PredictionMarket deployed) {
        address owner = vm.envAddress("PREDICTION_MARKET_OWNER");
        address creationAgent = vm.envAddress("PREDICTION_MARKET_CREATION_AGENT");
        address resolutionAgent = vm.envAddress("PREDICTION_MARKET_RESOLUTION_AGENT");
        address paymentToken = vm.envAddress("PREDICTION_MARKET_PAYMENT_TOKEN");
        address feeRecipient = vm.envAddress("PREDICTION_MARKET_FEE_RECIPIENT");
        address approvalAuthority = vm.envOr("PREDICTION_MARKET_APPROVAL_AUTHORITY", owner);
        bool requireApproval = vm.envOr("PREDICTION_MARKET_REQUIRE_TRADER_APPROVAL", false);

        uint64 disputeWindow = uint64(vm.envUint("PREDICTION_MARKET_DISPUTE_WINDOW"));
        uint256 disputeBond = vm.envUint("PREDICTION_MARKET_DISPUTE_BOND");

        vm.startBroadcast();
        deployed = new PredictionMarket(
            owner,
            creationAgent,
            resolutionAgent,
            paymentToken,
            feeRecipient,
            disputeWindow,
            disputeBond
        );

        if (approvalAuthority != owner) {
            deployed.setApprovalAuthority(approvalAuthority);
        }
        if (requireApproval) {
            deployed.setRequireTraderApproval(true);
        }

        vm.stopBroadcast();

        vm.label(address(deployed), "PredictionMarket");
        console2.log("PredictionMarket deployed at:", address(deployed));
        console2.log("Approval authority:", deployed.approvalAuthority());
        console2.log("Trader approvals required:", deployed.traderApprovalRequired());
    }
}

