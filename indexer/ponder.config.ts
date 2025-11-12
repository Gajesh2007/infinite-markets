import { createConfig } from "ponder";

import type { Address } from "viem";

import { PredictionMarketAbi } from "./abis/PredictionMarketAbi";

const rpcUrl =
  process.env.PONDER_RPC_URL ?? process.env.PONDER_RPC_URL_1 ?? process.env.PONDER_RPC_URL_8453;
if (!rpcUrl) {
  throw new Error("Missing RPC URL. Set PONDER_RPC_URL (or *_1 / *_8453) in the environment.");
}

const contractAddress = process.env.PREDICTION_MARKET_ADDRESS as Address | undefined;
if (!contractAddress) {
  throw new Error("Missing PREDICTION_MARKET_ADDRESS environment variable.");
}

const chainIdEnv = process.env.PREDICTION_MARKET_CHAIN_ID ?? process.env.PONDER_CHAIN_ID ?? "1";
const chainId = Number(chainIdEnv);
if (!Number.isInteger(chainId)) {
  throw new Error(`Invalid chain id: ${chainIdEnv}`);
}

const startBlockEnv = process.env.PREDICTION_MARKET_START_BLOCK ?? "0";
const startBlock = Number(startBlockEnv);
if (!Number.isInteger(startBlock) || startBlock < 0) {
  throw new Error(`Invalid start block: ${startBlockEnv}`);
}

const chainName = process.env.PONDER_CHAIN_NAME ?? "mainnet";

export default createConfig({
  chains: {
    [chainName]: {
      id: chainId,
      rpc: rpcUrl,
    },
  },
  contracts: {
    PredictionMarket: {
      chain: chainName,
      abi: PredictionMarketAbi,
      address: contractAddress,
      startBlock,
    },
  },
});
