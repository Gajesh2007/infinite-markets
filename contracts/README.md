## Prediction Market Contracts

This package holds the on-chain logic for the agent-native prediction market. It exposes a single production contract (`PredictionMarket.sol`), its canonical interface (`IPredictionMarket.sol`), a comprehensive Foundry test suite, and deployment automation.

---

### Components

| Path | Purpose |
| --- | --- |
| `src/PredictionMarket.sol` | Collateralized binary market with order book, dispute, and payout flows |
| `src/IPredictionMarket.sol` | Shared ABI with custom errors/events consumed by agents and tooling |
| `test/PredictionMarket.t.sol` | 38 scenario-driven tests covering lifecycle, edge cases, and access control |
| `script/PredictionMarketDeploy.s.sol` | Foundry deployment script parameterized via environment variables |

---

## Getting Started

### Prerequisites

- [Foundry toolchain](https://book.getfoundry.sh/getting-started/installation) (Forge ≥ 0.2.0 recommended)
- Access to an RPC endpoint and deployer private key for your target network
- ERC20 token address used as the wrapped-USDC collateral

### Install Dependencies

```bash
forge install
```

### Build

```bash
forge build
```

### Test

```bash
forge test -vv
```

The suite exercises market creation, order submission/filling, slippage guards, expirations, dispute flows (including bond escrow), fee siphoning, and payout invariants.

### Format

```bash
forge fmt
```

---

## Deployment

Deployment is performed via the Foundry script `PredictionMarketDeploy.s.sol`. Configuration is supplied through environment variables so the same script can target multiple environments.

### Required Environment Variables

| Variable | Description |
| --- | --- |
| `PREDICTION_MARKET_OWNER` | Admin address with the ability to rotate agents, payment token, and finalize markets |
| `PREDICTION_MARKET_CREATION_AGENT` | Agent allowed to create markets |
| `PREDICTION_MARKET_RESOLUTION_AGENT` | Agent allowed to resolve markets |
| `PREDICTION_MARKET_PAYMENT_TOKEN` | ERC20 collateral token address (wrapped USDC) |
| `PREDICTION_MARKET_FEE_RECIPIENT` | Address that receives trading fees |
| `PREDICTION_MARKET_APPROVAL_AUTHORITY` | (Optional) Address permitted to manage the trading allowlist (defaults to owner) |
| `PREDICTION_MARKET_REQUIRE_TRADER_APPROVAL` | (Optional) Set to `true` to enforce allowlisted trading immediately after deployment |
| `PREDICTION_MARKET_DISPUTE_WINDOW` | Dispute window length in seconds (e.g. `3600`) |
| `PREDICTION_MARKET_DISPUTE_BOND` | Dispute bond amount denominated in the payment token |

Example `.env` snippet:

```bash
export PREDICTION_MARKET_OWNER=0xYourOwnerAddress
export PREDICTION_MARKET_CREATION_AGENT=0xCreationAgent
export PREDICTION_MARKET_RESOLUTION_AGENT=0xResolutionAgent
export PREDICTION_MARKET_PAYMENT_TOKEN=0xCollateralToken
export PREDICTION_MARKET_FEE_RECIPIENT=0xFeeRecipient
export PREDICTION_MARKET_APPROVAL_AUTHORITY=0xApprovalAdmin   # optional (defaults to owner)
export PREDICTION_MARKET_REQUIRE_TRADER_APPROVAL=true          # optional
export PREDICTION_MARKET_DISPUTE_WINDOW=3600
export PREDICTION_MARKET_DISPUTE_BOND=5000000
```

Ensure your deployer key and RPC URL are also set (`PRIVATE_KEY`, `RPC_URL`, etc.).

### Run the Script

```bash
forge script script/PredictionMarketDeploy.s.sol:PredictionMarketDeploy \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

If you omit `--broadcast`, the script will execute in simulation mode—useful for forks or test rehearsals.

The script logs the deployed contract address and labels it in the Foundry trace for easy inspection.

---

## Operational Notes

- **Admin Rotation**: Use `setCreationAgent`, `setResolutionAgent`, `setFeeRecipient`, and `setPaymentToken` to rotate privileged addresses when the owning multisig dictates.
- **Trader Allowlist**: Toggle approvals with `setRequireTraderApproval`. The approval authority (set via `setApprovalAuthority`) manages entries through `setTraderApproval`.
- **Fees**: Fees are expressed in basis points (1e-4). The contract enforces `feeBps <= 10_000`.
- **Disputes**: Calling `disputeMarket` escrows the configured bond and toggles `MarketStatus.Disputed`. `finalizeMarket` must be called after the dispute window to release/return the bond.
- **Artifacts**: ABI and bytecode live in `out/` after `forge build`. Agents should cache `out/IPredictionMarket.sol/IPredictionMarket.json`.

For deeper Foundry usage (snapshots, gas reports, debugger) consult the [official docs](https://book.getfoundry.sh/).
