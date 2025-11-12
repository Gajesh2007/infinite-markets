import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { decodeFunctionData, zeroAddress } from "viem";
import type { Address, Hash } from "viem";

import { PredictionMarketAbi } from "../abis/PredictionMarketAbi";

const PRICE_SCALE = 1_000_000n;
const MAX_FEE_BPS = 10_000n;

const OUTCOME_LABELS = ["Undefined", "Yes", "No"] as const;
const ORDER_TYPE_LABELS = ["GoodTilCancel", "ImmediateOrCancel", "FillOrKill"] as const;
const STATUS_LABELS = ["Draft", "Active", "Paused", "Resolved", "Disputed", "Finalized", "Cancelled"] as const;

type OutcomeLabel = (typeof OUTCOME_LABELS)[number];
type StrictOutcome = "Yes" | "No";
type OrderTypeLabel = (typeof ORDER_TYPE_LABELS)[number];

const ZERO_ADDRESS: Address = zeroAddress;

const {
  markets,
  orders,
  fills,
  positions,
  traderApprovals,
  tradingConfig,
  disputes,
} = schema;

const GLOBAL_CONFIG_ID = "global";

const parseOutcome = (value: bigint | number): OutcomeLabel => {
  const index = Number(value);
  return OUTCOME_LABELS[index] ?? "Undefined";
};

const parseOrderType = (value: bigint | number): OrderTypeLabel => {
  const index = Number(value);
  return ORDER_TYPE_LABELS[index] ?? "GoodTilCancel";
};

const parseStatus = (value: bigint | number): string => {
  const index = Number(value);
  return STATUS_LABELS[index] ?? "Active";
};

const toId = (value: bigint | string): string => {
  if (typeof value === "bigint") return value.toString();
  return BigInt(value).toString();
};

const toAddress = (value: string): Address => value.toLowerCase() as Address;

const isStrictOutcome = (outcome: OutcomeLabel): outcome is StrictOutcome =>
  outcome === "Yes" || outcome === "No";

const opposite = (outcome: StrictOutcome): StrictOutcome => (outcome === "Yes" ? "No" : "Yes");

const stakeFor = (outcome: StrictOutcome, price: bigint, quantity: bigint): bigint => {
  if (quantity === 0n) return 0n;
  if (outcome === "Yes") {
    return (price * quantity) / PRICE_SCALE;
  }
  return ((PRICE_SCALE - price) * quantity) / PRICE_SCALE;
};

const upsertTradingConfig = async ({
  context,
  approvalRequired,
  blockNumber,
  blockTimestamp,
  transactionHash,
}: {
  context: Parameters<Parameters<typeof ponder.on>[1]>[0]["context"];
  approvalRequired: boolean;
  blockNumber: bigint;
  blockTimestamp: bigint;
  transactionHash: Hash;
}) => {
  await context.db
    .insert(tradingConfig)
    .values({
      id: GLOBAL_CONFIG_ID,
      approvalRequired,
      updatedBlock: blockNumber,
      updatedTimestamp: blockTimestamp,
      updatedTransaction: transactionHash,
    })
    .onConflictDoUpdate({
      approvalRequired,
      updatedBlock: blockNumber,
      updatedTimestamp: blockTimestamp,
      updatedTransaction: transactionHash,
    });
};

const incrementPosition = async ({
  context,
  marketId,
  trader,
  outcome,
  quantity,
  blockNumber,
  blockTimestamp,
  transactionHash,
}: {
  context: Parameters<Parameters<typeof ponder.on>[1]>[0]["context"];
  marketId: string;
  trader: Address;
  outcome: StrictOutcome;
  quantity: bigint;
  blockNumber: bigint;
  blockTimestamp: bigint;
  transactionHash: Hash;
}) => {
  const id = `${marketId}:${trader}:${outcome}`;
  await context.db
    .insert(positions)
    .values({
      id,
      marketId,
      trader,
      outcome,
      shares: quantity,
      updatedBlock: blockNumber,
      updatedTimestamp: blockTimestamp,
      updatedTransaction: transactionHash,
    })
    .onConflictDoUpdate((row) => ({
      shares: row.shares + quantity,
      updatedBlock: blockNumber,
      updatedTimestamp: blockTimestamp,
      updatedTransaction: transactionHash,
    }));
};

const resetPosition = async ({
  context,
  marketId,
  trader,
  outcome,
  blockNumber,
  blockTimestamp,
  transactionHash,
}: {
  context: Parameters<Parameters<typeof ponder.on>[1]>[0]["context"];
  marketId: string;
  trader: Address;
  outcome: StrictOutcome;
  blockNumber: bigint;
  blockTimestamp: bigint;
  transactionHash: Hash;
}) => {
  const id = `${marketId}:${trader}:${outcome}`;
  await context.db
    .insert(positions)
    .values({
      id,
      marketId,
      trader,
      outcome,
      shares: 0n,
      updatedBlock: blockNumber,
      updatedTimestamp: blockTimestamp,
      updatedTransaction: transactionHash,
    })
    .onConflictDoUpdate({
      shares: 0n,
      updatedBlock: blockNumber,
      updatedTimestamp: blockTimestamp,
      updatedTransaction: transactionHash,
    });
};

ponder.on("PredictionMarket:MarketCreated", async ({ event, context }) => {
  const marketId = toId(String(event.args.marketId));
  const creator = toAddress(event.args.creator as string);
  const questionUri = event.args.questionURI as string;
  const oracleUri = event.args.oracleURI as string;
  const openEpoch = BigInt(String(event.args.openEpoch));
  const closeEpoch = BigInt(String(event.args.closeEpoch));
  const feeBps = BigInt(String(event.args.feeBps));

  await context.db
    .insert(markets)
    .values({
      id: marketId,
      status: "Active",
      outcome: "Undefined",
      openEpoch,
      closeEpoch,
      feeBps,
      questionUri,
      oracleUri,
      resolutionUri: null,
      evidenceUri: null,
      creator,
      resolver: null,
      totalCollateral: 0n,
      disputeActive: false,
      disputeOpenedAt: null,
      disputeBond: null,
      createdBlock: event.block.number,
      createdTimestamp: event.block.timestamp,
      updatedBlock: event.block.number,
      updatedTimestamp: event.block.timestamp,
      lastTransactionHash: event.transaction.hash,
      resolvedAt: null,
      finalizedAt: null,
    })
    .onConflictDoUpdate({
      status: "Active",
      outcome: "Undefined",
      openEpoch,
      closeEpoch,
      feeBps,
      questionUri,
      oracleUri,
      creator,
      disputeActive: false,
      disputeOpenedAt: null,
      disputeBond: null,
      updatedBlock: event.block.number,
      updatedTimestamp: event.block.timestamp,
      lastTransactionHash: event.transaction.hash,
    });
});

ponder.on("PredictionMarket:MarketStatusUpdated", async ({ event, context }) => {
  const marketId = toId(String(event.args.marketId));
  const status = parseStatus(Number(event.args.status));

  await context.db
    .update(markets, { id: marketId })
    .set({
      status,
      updatedBlock: event.block.number,
      updatedTimestamp: event.block.timestamp,
      lastTransactionHash: event.transaction.hash,
    });
});

ponder.on("PredictionMarket:MarketResolved", async ({ event, context }) => {
  const marketId = toId(String(event.args.marketId));
  const outcome = parseOutcome(Number(event.args.outcome));
  const resolver = toAddress(event.args.resolver as string);
  const resolutionUri = event.args.resolutionURI as string;
  const evidenceUri = event.args.evidenceURI as string;

  await context.db
    .update(markets, { id: marketId })
    .set({
      status: "Resolved",
      outcome,
      resolver,
      resolutionUri,
      evidenceUri,
      resolvedAt: event.block.timestamp,
      disputeActive: false,
      disputeBond: null,
      disputeOpenedAt: null,
      updatedBlock: event.block.number,
      updatedTimestamp: event.block.timestamp,
      lastTransactionHash: event.transaction.hash,
    });

  await context.db.delete(disputes, { marketId });
});

ponder.on("PredictionMarket:MarketDisputed", async ({ event, context }) => {
  const marketId = toId(String(event.args.marketId));
  const evidenceUri = event.args.evidenceURI as string;
  const bondAmount = BigInt(String(event.args.bondAmount));
  const disputant = toAddress(event.args.disputant as string);

  await context.db
    .update(markets, { id: marketId })
    .set({
      status: "Disputed",
      disputeActive: true,
      disputeOpenedAt: event.block.timestamp,
      disputeBond: bondAmount,
      updatedBlock: event.block.number,
      updatedTimestamp: event.block.timestamp,
      lastTransactionHash: event.transaction.hash,
    });

  await context.db
    .insert(disputes)
    .values({
      marketId,
      evidenceUri,
      bondAmount,
      openedAt: event.block.timestamp,
      disputant,
      blockNumber: event.block.number,
      blockTimestamp: event.block.timestamp,
      transactionHash: event.transaction.hash as Hash,
    })
    .onConflictDoUpdate({
      evidenceUri,
      bondAmount,
      openedAt: event.block.timestamp,
      disputant,
      blockNumber: event.block.number,
      blockTimestamp: event.block.timestamp,
      transactionHash: event.transaction.hash as Hash,
    });
});

ponder.on("PredictionMarket:MarketFinalized", async ({ event, context }) => {
  const marketId = toId(String(event.args.marketId));

  await context.db
    .update(markets, { id: marketId })
    .set({
      status: "Finalized",
      finalizedAt: event.block.timestamp,
      disputeActive: false,
      disputeOpenedAt: null,
      disputeBond: null,
      updatedBlock: event.block.number,
      updatedTimestamp: event.block.timestamp,
      lastTransactionHash: event.transaction.hash,
    });

  await context.db.delete(disputes, { marketId });
});

ponder.on("PredictionMarket:OrderPlaced", async ({ event, context }) => {
  const orderId = toId(String(event.args.orderId));
  const marketId = toId(String(event.args.marketId));
  const owner = toAddress(event.args.trader as string);
  const position = parseOutcome(Number(event.args.position));
  const price = BigInt(String(event.args.price));
  const quantity = BigInt(String(event.args.quantity));
  const orderType = parseOrderType(Number(event.args.orderType));
  const expirationEpoch = BigInt(String(event.args.expirationEpoch));

  if (!isStrictOutcome(position)) {
    throw new Error(`Unexpected outcome for order ${orderId}: ${position}`);
  }

  let beneficiary: Address = owner;

  try {
    const decoded = decodeFunctionData({
      abi: PredictionMarketAbi,
      data: event.transaction.input,
    });

    if (decoded.functionName === "submitOrder") {
      const [submission] = decoded.args as readonly [
        {
          recipient: Address;
        }
      ];
      const recipient = submission.recipient;
      if (recipient && recipient.toLowerCase() !== ZERO_ADDRESS) {
        beneficiary = toAddress(recipient);
      }
    }
  } catch (error) {
    console.warn(`Failed to decode submitOrder calldata for order ${orderId}:`, error);
  }

  await context.db.insert(orders).values({
    id: orderId,
    marketId,
    owner,
    beneficiary,
    position,
    price,
    quantity,
    filled: 0n,
    orderType,
    expirationEpoch,
    active: true,
    createdBlock: event.block.number,
    createdTimestamp: event.block.timestamp,
    createdTransaction: event.transaction.hash as Hash,
    updatedBlock: event.block.number,
    updatedTimestamp: event.block.timestamp,
    updatedTransaction: event.transaction.hash as Hash,
    lastFillBlock: null,
    lastFillTimestamp: null,
  });
});

ponder.on("PredictionMarket:OrderFilled", async ({ event, context }) => {
  const orderId = toId(String(event.args.orderId));
  const marketId = toId(String(event.args.marketId));
  const quantityFilled = BigInt(String(event.args.quantity));
  const fee = BigInt(String(event.args.fee));
  const filler = toAddress(event.args.filler as string);
  const takerRecipient = toAddress(event.args.recipient as string);
  const blockNumber = event.block.number;
  const blockTimestamp = event.block.timestamp;
  const transactionHash = event.transaction.hash as Hash;
  const logIndex = BigInt(String(event.log.logIndex ?? 0));

  const orderRow = await context.db.find(orders, { id: orderId });
  if (!orderRow) {
    console.warn(`Order ${orderId} missing in indexer state; skipping fill ingestion.`);
    return;
  }

  const makerOutcome = orderRow.position as OutcomeLabel;
  if (!isStrictOutcome(makerOutcome)) {
    throw new Error(`Unexpected maker outcome for order ${orderId}: ${makerOutcome}`);
  }
  const takerOutcome = opposite(makerOutcome);
  const makerBeneficiary = toAddress(orderRow.beneficiary as string);
  const newFilled = orderRow.filled + quantityFilled;
  const stillActive = newFilled < orderRow.quantity;

  await context.db.update(orders, { id: orderId }).set({
    filled: newFilled,
    active: stillActive,
    updatedBlock: blockNumber,
    updatedTimestamp: blockTimestamp,
    updatedTransaction: transactionHash,
    lastFillBlock: blockNumber,
    lastFillTimestamp: blockTimestamp,
  });

  await context.db.update(markets, { id: marketId }).set((row) => ({
    totalCollateral: row.totalCollateral + quantityFilled,
    updatedBlock: blockNumber,
    updatedTimestamp: blockTimestamp,
    lastTransactionHash: transactionHash,
  }));

  const takerCost = stakeFor(takerOutcome, orderRow.price, quantityFilled);

  await context.db.insert(fills).values({
    id: event.id,
    orderId,
    marketId,
    makerPosition: makerOutcome,
    takerOutcome,
    filler,
    recipient: takerRecipient,
    quantity: quantityFilled,
    price: orderRow.price,
    fee,
    cost: takerCost,
    blockNumber,
    blockTimestamp,
    transactionHash,
    logIndex,
  });

  await incrementPosition({
    context,
    marketId,
    trader: makerBeneficiary,
    outcome: makerOutcome,
    quantity: quantityFilled,
    blockNumber,
    blockTimestamp,
    transactionHash,
  });

  await incrementPosition({
    context,
    marketId,
    trader: takerRecipient,
    outcome: takerOutcome,
    quantity: quantityFilled,
    blockNumber,
    blockTimestamp,
    transactionHash,
  });
});

ponder.on("PredictionMarket:OrderCancelled", async ({ event, context }) => {
  const orderId = toId(String(event.args.orderId));
  const remainingQuantity = BigInt(String(event.args.remainingQuantity));

  const orderRow = await context.db.find(orders, { id: orderId });
  if (!orderRow) {
    return;
  }

  const newFilled = orderRow.quantity - remainingQuantity;

  await context.db.update(orders, { id: orderId }).set({
    active: false,
    filled: newFilled,
    updatedBlock: event.block.number,
    updatedTimestamp: event.block.timestamp,
    updatedTransaction: event.transaction.hash as Hash,
  });
});

ponder.on("PredictionMarket:PayoutClaimed", async ({ event, context }) => {
  const marketId = toId(String(event.args.marketId));
  const claimant = toAddress(event.args.claimant as string);
  const outcome = parseOutcome(Number(event.args.position));

  if (!isStrictOutcome(outcome)) {
    return;
  }

  await resetPosition({
    context,
    marketId,
    trader: claimant,
    outcome,
    blockNumber: event.block.number,
    blockTimestamp: event.block.timestamp,
    transactionHash: event.transaction.hash as Hash,
  });
});

ponder.on("PredictionMarket:TraderApprovalRequirementUpdated", async ({ event, context }) => {
  const approvalRequired = Boolean(event.args.required);
  await upsertTradingConfig({
    context,
    approvalRequired,
    blockNumber: event.block.number,
    blockTimestamp: event.block.timestamp,
    transactionHash: event.transaction.hash as Hash,
  });
});

ponder.on("PredictionMarket:TraderApprovalUpdated", async ({ event, context }) => {
  const trader = toAddress(event.args.trader as string);
  const approved = Boolean(event.args.approved);

  await context.db
    .insert(traderApprovals)
    .values({
      trader,
      approved,
      updatedBlock: event.block.number,
      updatedTimestamp: event.block.timestamp,
      updatedTransaction: event.transaction.hash as Hash,
    })
    .onConflictDoUpdate({
      approved,
      updatedBlock: event.block.number,
      updatedTimestamp: event.block.timestamp,
      updatedTransaction: event.transaction.hash as Hash,
    });
});
