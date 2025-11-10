// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Agent-Only Prediction Market Interface
/// @notice Defines the core surface area for collateral management, market lifecycle, order flow, and resolution for the agent-native prediction market.
/// @dev All implementations MUST enforce access control on privileged flows (e.g. market creation/resolution agents) and MUST anchor evidence bundles off-chain using stable URIs (EigenDA or equivalent).
interface IPredictionMarket {
    /// @notice Unique identifier for a market.
    /// @dev Wrapper type to avoid accidental mixing of markets with other ids.
    type MarketId is uint256;

    /// @notice Unique identifier for an order.
    /// @dev Wrapper type to provide type-safety around order management.
    type OrderId is uint256;

    /// @notice Encodes the resolution state for a binary market.
    enum Outcome {
        Undefined,
        Yes,
        No
    }

    /// @notice Tracks the high-level lifecycle of a market.
    enum MarketStatus {
        Draft,
        Active,
        Paused,
        Resolved,
        Disputed,
        Finalized,
        Cancelled
    }

    /// @notice Declares how an order should persist on the book.
    enum OrderType {
        GoodTilCancel,
        ImmediateOrCancel,
        FillOrKill
    }

    /// @notice Identifies address fields subject to zero-address validation.
    enum AddressField {
        Owner,
        CreationAgent,
        ResolutionAgent,
        PaymentToken,
        FeeRecipient,
        ApprovalAuthority,
        Trader
    }

    /// @notice Captures immutable metadata for a market when it is created.
    struct MarketCreation {
        /// @notice URI pointing to the canonical market question and rule metadata.
        string questionURI;
        /// @notice URI describing the default source-of-truth reference the adjudication agent must consult.
        string oracleURI;
        /// @notice Unix timestamp (seconds) when trading opens.
        uint64 openEpoch;
        /// @notice Unix timestamp (seconds) when new orders are no longer accepted.
        uint64 closeEpoch;
        /// @notice Fee applied to matched orders in basis points (1e-2% precision).
        uint16 feeBps;
    }

    /// @notice Provides a snapshot view of a market's mutable state.
    struct MarketView {
        /// @notice Lifecycle status of the market.
        MarketStatus status;
        /// @notice Outcome currently recorded on-chain.
        Outcome outcome;
        /// @notice Indicates whether the resolution outcome has passed the dispute window.
        bool finalizable;
        /// @notice Timestamp when the market opened for trading.
        uint64 openEpoch;
        /// @notice Timestamp when trading closed.
        uint64 closeEpoch;
        /// @notice Fee applied to matched orders in basis points.
        uint16 feeBps;
        /// @notice URI for the canonical market question and rule metadata.
        string questionURI;
        /// @notice URI for the default source-of-truth reference.
        string oracleURI;
        /// @notice URI anchoring the resolver's evidence package.
        string resolutionURI;
        /// @notice URI anchoring raw source material captured during resolution.
        string resolutionEvidenceURI;
        /// @notice Address of the account that originally created the market.
        address creator;
        /// @notice Address that resolved the market (zero if unresolved).
        address resolver;
    }

    /// @notice Parameters for submitting a limit order into the book.
    struct OrderSubmission {
        /// @notice Market the order targets.
        MarketId marketId;
        /// @notice Position exposure requested (YES or NO token).
        Outcome position;
        /// @notice Price quote scaled by 1e6 (e.g. 0.42 USDC => 420_000).
        uint128 price;
        /// @notice Quantity of collateral (scaled in underlying decimals) offered or requested.
        uint128 quantity;
        /// @notice Desired persistence semantics for the order.
        OrderType orderType;
        /// @notice Unix timestamp when the order expires; ignored for FillOrKill.
        uint64 expirationEpoch;
        /// @notice Recipient of position tokens (defaults to msg.sender if zero).
        address recipient;
    }

    /// @notice Arguments for filling an existing order.
    struct OrderFill {
        /// @notice Identifier of the order to fill.
        OrderId orderId;
        /// @notice Maximum price the filler is willing to pay (scaled by 1e6).
        uint128 limitPrice;
        /// @notice Quantity of collateral to match from the resting order.
        uint128 quantity;
        /// @notice Address receiving the resulting position tokens.
        address recipient;
    }

    /// @notice Evidence submitted by the adjudication agent to resolve a market.
    struct Resolution {
        /// @notice Outcome asserted by the resolver.
        Outcome outcome;
        /// @notice URI of the bundle containing transcripts, browser captures, and proofs.
        string resolutionURI;
        /// @notice URI of raw source data attested during resolution (e.g., article snapshot).
        string evidenceURI;
        /// @notice Timestamp when the resolution was produced.
        uint64 resolvedAt;
    }

    /// @notice Captures details about a submitted dispute.
    struct Dispute {
        /// @notice URI of the payload backing the dispute evidence.
        string evidenceURI;
        /// @notice Amount of collateral escrowed by the disputant.
        uint256 bondAmount;
        /// @notice Timestamp when the dispute was opened.
        uint64 openedAt;
        /// @notice Address that initiated the dispute.
        address disputant;
    }

    /// @notice Provides a read-only view of an order's state.
    struct OrderView {
        /// @notice Identifier for the order.
        OrderId orderId;
        /// @notice Market the order belongs to.
        MarketId marketId;
        /// @notice Account that submitted the order.
        address owner;
        /// @notice Position requested (YES or NO).
        Outcome position;
        /// @notice Price quoted when the order was submitted (scaled by 1e6).
        uint128 price;
        /// @notice Total quantity originally requested.
        uint128 quantity;
        /// @notice Quantity that has already been filled.
        uint128 filled;
        /// @notice Desired persistence semantics for the order.
        OrderType orderType;
        /// @notice Timestamp when the order expires (ignored for FillOrKill).
        uint64 expirationEpoch;
        /// @notice Indicates whether the order is still live on the book.
        bool active;
    }

    /// @notice Emitted after a market is created.
    /// @param marketId Newly assigned market identifier.
    /// @param creator Actor that initiated the market creation.
    /// @param questionURI URI referencing the canonical question payload.
    /// @param oracleURI URI referencing the agreed source-of-truth artifact.
    /// @param openEpoch Timestamp when the market opens.
    /// @param closeEpoch Timestamp when the market closes.
    /// @param feeBps Fee in basis points applied per matched order.
    event MarketCreated(
        MarketId indexed marketId,
        address indexed creator,
        string questionURI,
        string oracleURI,
        uint64 openEpoch,
        uint64 closeEpoch,
        uint16 feeBps
    );

    /// @notice Emitted when the protocol pauses or resumes trading on a market.
    /// @param marketId Market affected.
    /// @param status New status for the market.
    event MarketStatusUpdated(MarketId indexed marketId, MarketStatus status);

    /// @notice Emitted after an order is submitted to the book.
    /// @param orderId Unique identifier for the order.
    /// @param marketId Market the order belongs to.
    /// @param trader Account responsible for the order.
    /// @param position Position requested (YES or NO).
    /// @param price Quoted price scaled by 1e6.
    /// @param quantity Size of the order in collateral units.
    /// @param orderType Persistence semantics requested.
    /// @param expirationEpoch Expiration timestamp for the order.
    event OrderPlaced(
        OrderId indexed orderId,
        MarketId indexed marketId,
        address indexed trader,
        Outcome position,
        uint128 price,
        uint128 quantity,
        OrderType orderType,
        uint64 expirationEpoch
    );

    /// @notice Emitted when an existing order is cancelled.
    /// @param orderId Identifier for the cancelled order.
    /// @param marketId Market the order belonged to.
    /// @param trader Account that owned the order.
    /// @param remainingQuantity Quantity that remained unfilled prior to cancellation.
    event OrderCancelled(
        OrderId indexed orderId,
        MarketId indexed marketId,
        address indexed trader,
        uint128 remainingQuantity
    );

    /// @notice Emitted when an order is filled.
    /// @param orderId Resting order identifier.
    /// @param marketId Market associated with the fill.
    /// @param owner Account that owned the resting order.
    /// @param filler Account that executed the fill.
    /// @param quantity Quantity matched during the fill.
    /// @param price Price applied to the fill (scaled by 1e6).
    /// @param fee Amount of trading fee collected.
    /// @param recipient Address receiving the resulting position tokens.
    event OrderFilled(
        OrderId indexed orderId,
        MarketId indexed marketId,
        address indexed owner,
        address filler,
        uint128 quantity,
        uint128 price,
        uint256 fee,
        address recipient
    );

    /// @notice Emitted when a market resolution is recorded.
    /// @param marketId Market that was resolved.
    /// @param outcome Outcome declared.
    /// @param resolutionURI URI of the bundle containing resolution evidence.
    /// @param evidenceURI URI of the raw source-of-truth artifact.
    /// @param resolver Account that posted the resolution.
    event MarketResolved(
        MarketId indexed marketId,
        Outcome outcome,
        string resolutionURI,
        string evidenceURI,
        address indexed resolver
    );

    /// @notice Emitted when a dispute is lodged against a resolution.
    /// @param marketId Market under dispute.
    /// @param disputant Account that initiated the dispute.
    /// @param evidenceURI URI of the dispute evidence stored off-chain.
    /// @param bondAmount Collateral bonded by the disputant.
    event MarketDisputed(
        MarketId indexed marketId,
        address indexed disputant,
        string evidenceURI,
        uint256 bondAmount
    );

    /// @notice Emitted when a market is finalized after the dispute window.
    /// @param marketId Market that was finalized.
    /// @param outcome Outcome confirmed at finalization.
    /// @param resolutionURI URI of the final resolution evidence.
    event MarketFinalized(MarketId indexed marketId, Outcome outcome, string resolutionURI);

    /// @notice Emitted when a participant claims their payout.
    /// @param marketId Market being claimed.
    /// @param claimant Account that received the payout.
    /// @param position Position claimed (YES or NO).
    /// @param amount Amount of collateral paid out.
    event PayoutClaimed(MarketId indexed marketId, address indexed claimant, Outcome position, uint256 amount);

    /// @notice Emitted when the payment token is updated.
    /// @param token Address of the new ERC20 used for collateral.
    event PaymentTokenUpdated(address indexed token);
    /// @notice Emitted when the creation agent is rotated.
    event CreationAgentUpdated(address indexed agent);
    /// @notice Emitted when the resolution agent is rotated.
    event ResolutionAgentUpdated(address indexed agent);
    /// @notice Emitted when the fee recipient changes.
    event FeeRecipientUpdated(address indexed recipient);
    /// @notice Emitted when the approval authority changes.
    event TraderApprovalAuthorityUpdated(address indexed authority);
    /// @notice Emitted when the approval requirement flag is toggled.
    event TraderApprovalRequirementUpdated(bool required);
    /// @notice Emitted when a trader's allowlist status changes.
    event TraderApprovalUpdated(address indexed trader, bool approved);

    /// @notice Thrown when an account lacks sufficient available collateral for an operation.
    error InsufficientAvailableBalance(address account, uint256 requested, uint256 available);

    /// @notice Thrown when attempting to act on a market that is not active.
    error MarketNotActive(MarketId marketId, MarketStatus status);

    /// @notice Thrown when attempting to resolve a market before the protocol allows it.
    error ResolveWindowNotReached(MarketId marketId, uint64 currentTimestamp);

    /// @notice Thrown when attempting to dispute outside the permitted window.
    error DisputeWindowClosed(MarketId marketId);

    /// @notice Thrown when the provided outcome is invalid for the current market state.
    error InvalidOutcome(MarketId marketId, Outcome supplied);

    /// @notice Thrown when an order action references a non-existent order id.
    error UnknownOrder(OrderId orderId);

    /// @notice Thrown when an order fill exceeds the remaining quantity.
    error Overfill(OrderId orderId, uint128 requested, uint128 remaining);

    /// @notice Thrown when a caller lacks authorization for a privileged action.
    error Unauthorized(address caller);

    /// @notice Thrown when the order type is unsupported by the venue.
    error UnsupportedOrderType(OrderType orderType);

    /// @notice Thrown when the quoted price lies outside of the allowed [0, 1) range.
    error InvalidPrice(uint128 supplied);

    /// @notice Thrown when a zero quantity is provided.
    error InvalidQuantity(uint128 supplied);

    /// @notice Thrown when placing an order outside the market's open window.
    error MarketClosed(MarketId marketId);

    /// @notice Thrown when attempting to act on an expired order.
    error OrderExpired(OrderId orderId, uint64 expirationEpoch);

    /// @notice Thrown when attempting to modify an inactive order.
    error OrderNotActive(OrderId orderId);

    /// @notice Thrown when a claimant lacks the winning position.
    error NoPosition(MarketId marketId, Outcome outcome, address account);

    /// @notice Thrown when attempting to claim twice for the same position.
    error AlreadyClaimed(MarketId marketId, address account);

    /// @notice Thrown when a dispute already exists for the market.
    error DisputeActive(MarketId marketId);

    /// @notice Thrown when an expiration parameter is in the past.
    error InvalidExpiration(uint64 supplied);

    /// @notice Thrown when a fill exceeds the taker's slippage tolerance.
    error SlippageExceeded(uint128 limitPrice, uint128 orderPrice);

    /// @notice Thrown when the supplied resolution timestamp predates the close epoch.
    error InvalidResolutionTimestamp(uint64 supplied, uint64 minimum);

    /// @notice Thrown when mandatory creation metadata is missing.
    error EmptyQuestionURI();

    /// @notice Thrown when the oracle URI is empty.
    error EmptyOracleURI();

    /// @notice Thrown when the resolution URI is empty.
    error EmptyResolutionURI();

    /// @notice Thrown when the evidence URI is empty.
    error EmptyEvidenceURI();

    /// @notice Thrown when the configured fee exceeds the protocol ceiling.
    error FeeTooHigh(uint16 supplied, uint16 maxAllowed);

    /// @notice Thrown when open/close epochs are inconsistent.
    error InvalidEpochRange(uint64 openEpoch, uint64 closeEpoch);

    /// @notice Thrown when a required address equals the zero address.
    error ZeroAddress(AddressField field);

    /// @notice Thrown when referencing a market id that does not exist.
    error UnknownMarket(MarketId marketId);

    /// @notice Thrown when finalization is attempted before a resolution exists.
    error MarketUnresolved();
    /// @notice Thrown when a trader attempts to interact while approvals are enforced.
    error TraderNotApproved(address trader);

    /// @notice Returns the ERC20 token address used for collateral payments.
    /// @return token Address of the payment token.
    function paymentToken() external view returns (address token);

    /// @notice Sets the ERC20 token address used for collateral payments.
    /// @param token Address of the ERC20 to accept as collateral.
    function setPaymentToken(address token) external;

    /// @notice Updates the privileged creation agent address.
    /// @param agent Address permitted to instantiate new markets.
    function setCreationAgent(address agent) external;

    /// @notice Updates the privileged resolution agent address.
    /// @param agent Address permitted to resolve markets.
    function setResolutionAgent(address agent) external;

    /// @notice Updates the address receiving protocol fees.
    /// @param recipient Address to receive fee distributions.
    function setFeeRecipient(address recipient) external;

    /// @notice Returns the address responsible for managing trader approvals.
    function approvalAuthority() external view returns (address authority);

    /// @notice Returns whether trading currently requires allowlisted traders.
    function traderApprovalRequired() external view returns (bool required);

    /// @notice Returns whether a trader address is allowlisted.
    function isTraderApproved(address trader) external view returns (bool approved);

    /// @notice Updates the trader approval authority.
    /// @param authority Address permitted to manage the allowlist.
    function setApprovalAuthority(address authority) external;

    /// @notice Enables or disables trader approval enforcement.
    /// @param required True to require approvals, false to allow open trading.
    function setRequireTraderApproval(bool required) external;

    /// @notice Adds or removes a trader from the allowlist.
    /// @param trader Address whose status is being updated.
    /// @param approved True to approve, false to revoke.
    function setTraderApproval(address trader, bool approved) external;

    /// @notice Creates a new market with the supplied configuration.
    /// @param params Market configuration payload as defined in MarketCreation.
    /// @return marketId Newly assigned market identifier.
    function createMarket(MarketCreation calldata params) external returns (MarketId marketId);

    /// @notice Provides a read-only snapshot of the market state.
    /// @param marketId Identifier of the market to query.
    /// @return market Struct describing the current market view.
    function getMarket(MarketId marketId) external view returns (MarketView memory market);

    /// @notice Returns the dispute record for a given market, if one exists.
    /// @param marketId Identifier for the market being queried.
    /// @return dispute Struct containing dispute information; zeroed if no dispute.
    function getDispute(MarketId marketId) external view returns (Dispute memory dispute);

    /// @notice Returns all active and historical orders submitted by an owner.
    /// @param owner Account whose orders are requested.
    /// @return orders Array containing order state snapshots.
    function getOrdersByOwner(address owner) external view returns (OrderView[] memory orders);

    /// @notice Submits a new limit order to the order book.
    /// @param order Struct encoding order instructions.
    /// @return orderId Identifier assigned to the new order.
    function submitOrder(OrderSubmission calldata order) external returns (OrderId orderId);

    /// @notice Cancels an existing order owned by the caller.
    /// @param orderId Identifier of the order to cancel.
    function cancelOrder(OrderId orderId) external;

    /// @notice Fills an existing resting order subject to the caller's price and quantity constraints.
    /// @param fill Struct specifying order fill parameters.
    /// @return cost Total collateral transferred from the filler.
    /// @return fee Trading fee charged for the fill.
    function fillOrder(OrderFill calldata fill) external returns (uint256 cost, uint256 fee);

    /// @notice Resolves a market by anchoring evidence and declaring an outcome.
    /// @param marketId Market being resolved.
    /// @param resolution Struct containing resolution details and evidence URIs.
    function resolveMarket(MarketId marketId, Resolution calldata resolution) external;

    /// @notice Opens a dispute against an existing resolution.
    /// @param marketId Market being disputed.
    /// @param evidenceURI URI of the evidence bundle supporting the dispute.
    function disputeMarket(MarketId marketId, string calldata evidenceURI) external;

    /// @notice Finalizes a market after the dispute window, enabling claims.
    /// @param marketId Market to finalize.
    function finalizeMarket(MarketId marketId) external;

    /// @notice Claims payout for a finalized market position.
    /// @param marketId Market to claim against.
    /// @param position Position being claimed (YES or NO).
    /// @param recipient Address receiving the payout; defaults to msg.sender if zero address.
    /// @return amount Amount of collateral paid to the recipient.
    function claimPayout(MarketId marketId, Outcome position, address recipient) external returns (uint256 amount);
}

