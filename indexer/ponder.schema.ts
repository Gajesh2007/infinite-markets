import { onchainTable } from "ponder";

export const markets = onchainTable("markets", (t) => ({
  id: t.text().primaryKey(),
  status: t.text().notNull(),
  outcome: t.text().notNull(),
  openEpoch: t.bigint().notNull(),
  closeEpoch: t.bigint().notNull(),
  feeBps: t.bigint().notNull(),
  questionUri: t.text().notNull(),
  oracleUri: t.text().notNull(),
  resolutionUri: t.text(),
  evidenceUri: t.text(),
  creator: t.hex().notNull(),
  resolver: t.hex(),
  totalCollateral: t.bigint().notNull(),
  disputeActive: t.boolean().notNull(),
  disputeOpenedAt: t.bigint(),
  disputeBond: t.bigint(),
  createdBlock: t.bigint().notNull(),
  createdTimestamp: t.bigint().notNull(),
  updatedBlock: t.bigint().notNull(),
  updatedTimestamp: t.bigint().notNull(),
  lastTransactionHash: t.hex().notNull(),
  resolvedAt: t.bigint(),
  finalizedAt: t.bigint(),
}));

export const orders = onchainTable("orders", (t) => ({
  id: t.text().primaryKey(),
  marketId: t.text().notNull(),
  owner: t.hex().notNull(),
  beneficiary: t.hex().notNull(),
  position: t.text().notNull(),
  price: t.bigint().notNull(),
  quantity: t.bigint().notNull(),
  filled: t.bigint().notNull(),
  orderType: t.text().notNull(),
  expirationEpoch: t.bigint().notNull(),
  active: t.boolean().notNull(),
  createdBlock: t.bigint().notNull(),
  createdTimestamp: t.bigint().notNull(),
  createdTransaction: t.hex().notNull(),
  updatedBlock: t.bigint().notNull(),
  updatedTimestamp: t.bigint().notNull(),
  updatedTransaction: t.hex().notNull(),
  lastFillBlock: t.bigint(),
  lastFillTimestamp: t.bigint(),
}));

export const fills = onchainTable("fills", (t) => ({
  id: t.text().primaryKey(),
  orderId: t.text().notNull(),
  marketId: t.text().notNull(),
  makerPosition: t.text().notNull(),
  takerOutcome: t.text().notNull(),
  filler: t.hex().notNull(),
  recipient: t.hex().notNull(),
  quantity: t.bigint().notNull(),
  price: t.bigint().notNull(),
  fee: t.bigint().notNull(),
  cost: t.bigint().notNull(),
  blockNumber: t.bigint().notNull(),
  blockTimestamp: t.bigint().notNull(),
  transactionHash: t.hex().notNull(),
  logIndex: t.bigint().notNull(),
}));

export const positions = onchainTable("positions", (t) => ({
  id: t.text().primaryKey(),
  marketId: t.text().notNull(),
  trader: t.hex().notNull(),
  outcome: t.text().notNull(),
  shares: t.bigint().notNull(),
  updatedBlock: t.bigint().notNull(),
  updatedTimestamp: t.bigint().notNull(),
  updatedTransaction: t.hex().notNull(),
}));

export const traderApprovals = onchainTable("trader_approvals", (t) => ({
  trader: t.hex().primaryKey(),
  approved: t.boolean().notNull(),
  updatedBlock: t.bigint().notNull(),
  updatedTimestamp: t.bigint().notNull(),
  updatedTransaction: t.hex().notNull(),
}));

export const tradingConfig = onchainTable("trading_config", (t) => ({
  id: t.text().primaryKey(),
  approvalRequired: t.boolean().notNull(),
  updatedBlock: t.bigint().notNull(),
  updatedTimestamp: t.bigint().notNull(),
  updatedTransaction: t.hex().notNull(),
}));

export const disputes = onchainTable("disputes", (t) => ({
  marketId: t.text().primaryKey(),
  evidenceUri: t.text().notNull(),
  bondAmount: t.bigint().notNull(),
  openedAt: t.bigint().notNull(),
  disputant: t.hex().notNull(),
  blockNumber: t.bigint().notNull(),
  blockTimestamp: t.bigint().notNull(),
  transactionHash: t.hex().notNull(),
}));
