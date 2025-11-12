import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import { client, graphql } from "ponder";

const app = new Hono();

const PRICE_SCALE = 1_000_000n;
const MAX_FEE_BPS = 10_000n;

type StrictOutcome = "Yes" | "No";

const stakeFor = (outcome: StrictOutcome, price: bigint, quantity: bigint): bigint => {
  if (quantity === 0n) return 0n;
  if (outcome === "Yes") {
    return (price * quantity) / PRICE_SCALE;
  }
  return ((PRICE_SCALE - price) * quantity) / PRICE_SCALE;
};

const normalizeBigInt = (value: unknown): bigint => {
  if (typeof value === "bigint") return value;
  if (typeof value === "number") return BigInt(value);
  if (typeof value === "string") return value.startsWith("0x") ? BigInt(value) : BigInt(value);
  throw new Error(`Unable to normalize value ${value}`);
};

type BookLevel = {
  price: string;
  remaining: string;
  cumulative: string;
};

type OrderRow = {
  id: string;
  position: StrictOutcome;
  price: bigint;
  quantity: bigint;
  filled: bigint;
};

const getMarketSummary = async (marketId: string) => {
  const rows = await db
    .select({
      id: schema.markets.id,
      status: schema.markets.status,
      outcome: schema.markets.outcome,
      feeBps: schema.markets.feeBps,
      disputeActive: schema.markets.disputeActive,
      totalCollateral: schema.markets.totalCollateral,
      updatedBlock: schema.markets.updatedBlock,
      updatedTimestamp: schema.markets.updatedTimestamp,
    })
    .from(schema.markets);

  return rows.find((row) => row.id === marketId) ?? null;
};

const loadActiveOrders = async (marketId: string): Promise<OrderRow[]> => {
  const rows = await db
    .select({
      id: schema.orders.id,
      marketId: schema.orders.marketId,
      position: schema.orders.position,
      price: schema.orders.price,
      quantity: schema.orders.quantity,
      filled: schema.orders.filled,
      active: schema.orders.active,
    })
    .from(schema.orders);

  return rows
    .filter((row) => row.marketId === marketId && row.active)
    .map((row) => ({
      id: row.id,
      position: row.position as StrictOutcome,
      price: normalizeBigInt(row.price),
      quantity: normalizeBigInt(row.quantity),
      filled: normalizeBigInt(row.filled),
    }))
    .filter((row) => (row.position === "Yes" || row.position === "No") && row.quantity > row.filled);
};

const buildBook = async (marketId: string) => {
  const orders = await loadActiveOrders(marketId);

  const yesOrders = orders
    .filter((order) => order.position === "Yes" && order.quantity > order.filled)
    .sort((a, b) => {
      if (a.price === b.price) return 0;
      return a.price > b.price ? -1 : 1;
    });

  const noOrders = orders
    .filter((order) => order.position === "No" && order.quantity > order.filled)
    .sort((a, b) => {
      if (a.price === b.price) return 0;
      return a.price < b.price ? -1 : 1;
    });

  const buildLevels = (rows: OrderRow[], sortAscending: boolean): BookLevel[] => {
    const sorted = [...rows].sort((a, b) => {
      if (a.price === b.price) return 0;
      if (sortAscending) {
        return a.price < b.price ? -1 : 1;
      }
      return a.price > b.price ? -1 : 1;
    });

    let cumulative = 0n;
    return sorted.map((row) => {
      const remaining = row.quantity - row.filled;
      cumulative += remaining;
      return {
        price: row.price.toString(),
        remaining: remaining.toString(),
        cumulative: cumulative.toString(),
      };
    });
  };

  return {
    yes: buildLevels(yesOrders, false),
    no: buildLevels(noOrders, true),
  };
};

app.get("/markets/:marketId/book", async (c) => {
  const marketId = c.req.param("marketId");
  if (!marketId) {
    return c.json({ error: "marketId is required" }, 400);
  }

  const market = await getMarketSummary(marketId);
  if (!market) {
    return c.json({ error: "Market not indexed" }, 404);
  }

  const book = await buildBook(marketId);

  return c.json({
    marketId,
    status: market.status,
    outcome: market.outcome,
    feeBps: normalizeBigInt(market.feeBps).toString(),
    disputeActive: Boolean(market.disputeActive),
    totalCollateral: normalizeBigInt(market.totalCollateral).toString(),
    updatedBlock: normalizeBigInt(market.updatedBlock).toString(),
    updatedTimestamp: normalizeBigInt(market.updatedTimestamp).toString(),
    yes: book.yes,
    no: book.no,
  });
});

app.get("/markets/:marketId/top-of-book", async (c) => {
  const marketId = c.req.param("marketId");
  if (!marketId) {
    return c.json({ error: "marketId is required" }, 400);
  }

  const market = await getMarketSummary(marketId);
  if (!market) {
    return c.json({ error: "Market not indexed" }, 404);
  }

  const book = await buildBook(marketId);

  return c.json({
    marketId,
    yes: book.yes[0] ?? null,
    no: book.no[0] ?? null,
    updatedBlock: normalizeBigInt(market.updatedBlock).toString(),
    updatedTimestamp: normalizeBigInt(market.updatedTimestamp).toString(),
  });
});

app.post("/plan-fill", async (c) => {
  const payload = (await c.req.json()) as {
    marketId?: string;
    outcome?: string;
    quantity?: string | number | bigint;
    limitPrice?: string | number | bigint;
  };

  const marketId = payload.marketId;
  if (!marketId) {
    return c.json({ error: "marketId is required" }, 400);
  }

  if (payload.outcome !== "Yes" && payload.outcome !== "No") {
    return c.json({ error: "outcome must be 'Yes' or 'No'" }, 400);
  }
  const desiredOutcome = payload.outcome as StrictOutcome;

  if (payload.quantity === undefined) {
    return c.json({ error: "quantity is required" }, 400);
  }
  const quantityRequested = normalizeBigInt(payload.quantity);
  if (quantityRequested <= 0) {
    return c.json({ error: "quantity must be positive" }, 400);
  }

  const limitPrice = payload.limitPrice !== undefined ? normalizeBigInt(payload.limitPrice) : undefined;
  if (limitPrice !== undefined && (limitPrice < 0n || limitPrice >= PRICE_SCALE)) {
    return c.json({ error: "limitPrice must be within [0, 1e6)" }, 400);
  }

  const market = await getMarketSummary(marketId);
  if (!market) {
    return c.json({ error: "Market not indexed" }, 404);
  }

  const orders = await loadActiveOrders(marketId);
  const makerSide: StrictOutcome = desiredOutcome === "Yes" ? "No" : "Yes";

  const relevant = orders
    .filter((order) => order.position === makerSide && order.quantity > order.filled)
    .sort((a, b) => {
      if (a.price === b.price) return 0;
      if (desiredOutcome === "Yes") {
        return a.price < b.price ? -1 : 1;
      }
      return a.price > b.price ? -1 : 1;
    });

  let remaining = quantityRequested;
  let totalCost = 0n;
  let totalFee = 0n;
  const marketFeeBps = normalizeBigInt(market.feeBps);

  const fillsPlan: Array<{
    orderId: string;
    makerPosition: StrictOutcome;
    price: string;
    quantity: string;
    takerCost: string;
    fee: string;
  }> = [];

  for (const order of relevant) {
    if (remaining === 0n) break;
    const available = order.quantity - order.filled;
    if (available <= 0n) continue;

    if (limitPrice !== undefined) {
      if (desiredOutcome === "Yes" && order.price > limitPrice) {
        continue;
      }
      if (desiredOutcome === "No") {
        const takerPrice = PRICE_SCALE - order.price;
        if (takerPrice > limitPrice) {
          continue;
        }
      }
    }

    const fillQuantity = available >= remaining ? remaining : available;
    const cost = stakeFor(desiredOutcome, order.price, fillQuantity);
    const fee = (fillQuantity * marketFeeBps) / MAX_FEE_BPS;

    fillsPlan.push({
      orderId: order.id,
      makerPosition: makerSide,
      price: order.price.toString(),
      quantity: fillQuantity.toString(),
      takerCost: cost.toString(),
      fee: fee.toString(),
    });

    remaining -= fillQuantity;
    totalCost += cost;
    totalFee += fee;
  }

  if (remaining > 0n) {
    return c.json(
      {
        error: "Insufficient liquidity to satisfy requested quantity",
        availableQuantity: (quantityRequested - remaining).toString(),
      },
      422,
    );
  }

  return c.json({
    marketId,
    desiredOutcome,
    totalQuantity: quantityRequested.toString(),
    totalCost: totalCost.toString(),
    totalFee: totalFee.toString(),
    fills: fillsPlan,
  });
});

app.use("/sql/*", client({ db, schema }));
app.use("/graphql", graphql({ db, schema }));

export default app;
