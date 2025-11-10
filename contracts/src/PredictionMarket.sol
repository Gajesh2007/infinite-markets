// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPredictionMarket} from "./IPredictionMarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PredictionMarket
/// @notice Implements the agent-first binary prediction market backed by EigenDA evidence.
/// @dev Uses OpenZeppelin ownership and reentrancy primitives. Collateral settles entirely through the configured ERC20 token.
contract PredictionMarket is IPredictionMarket, Ownable, ReentrancyGuard {
    uint256 private constant PRICE_SCALE = 1_000_000;
    uint256 private constant MAX_FEE_BPS = 10_000;

    struct Market {
        MarketStatus status;
        Outcome outcome;
        uint64 openEpoch;
        uint64 closeEpoch;
        uint64 resolvedAt;
        uint16 feeBps;
        bool disputeActive;
        string questionURI;
        string oracleURI;
        string resolutionURI;
        string resolutionEvidenceURI;
        address creator;
        address resolver;
        uint256 totalCollateral;
    }

    struct Order {
        uint256 marketKey;
        address owner;
        address beneficiary;
        Outcome position;
        uint128 price;
        uint128 quantity;
        uint128 filled;
        OrderType orderType;
        uint64 expirationEpoch;
        bool active;
    }

    IERC20 private _paymentToken;
    address public creationAgent;
    address public resolutionAgent;
    address public feeRecipient;
    uint64 public immutable disputeWindow;
    uint256 public immutable disputeBond;

    uint256 private _marketIdSequence;
    uint256 private _orderIdSequence;

    mapping(uint256 => Market) private _markets;
    mapping(uint256 => Order) private _orders;
    mapping(address => uint256[]) private _ordersByOwner;
    mapping(uint256 => Dispute) private _disputes;
    mapping(uint256 => mapping(address => mapping(uint8 => uint128))) private _positions;
    mapping(uint256 => mapping(address => bool)) private _hasClaimed;
    address private _approvalAuthority;
    bool private _traderApprovalRequired;
    mapping(address => bool) private _approvedTraders;

    modifier onlyCreationAgent() {
        require(_msgSender() == creationAgent, Unauthorized(_msgSender()));
        _;
    }

    modifier onlyResolutionAgent() {
        require(_msgSender() == resolutionAgent, Unauthorized(_msgSender()));
        _;
    }

    constructor(
        address owner_,
        address creationAgent_,
        address resolutionAgent_,
        address paymentToken_,
        address feeRecipient_,
        uint64 disputeWindow_,
        uint256 disputeBond_
    ) Ownable(_requireNonZero(owner_, AddressField.Owner)) {
        creationAgent = _requireNonZero(creationAgent_, AddressField.CreationAgent);
        resolutionAgent = _requireNonZero(resolutionAgent_, AddressField.ResolutionAgent);
        _paymentToken = IERC20(_requireNonZero(paymentToken_, AddressField.PaymentToken));
        feeRecipient = _requireNonZero(feeRecipient_, AddressField.FeeRecipient);
        disputeWindow = disputeWindow_;
        disputeBond = disputeBond_;
        _approvalAuthority = owner_;
        _approvedTraders[owner_] = true;
        _approvedTraders[creationAgent] = true;
        _approvedTraders[resolutionAgent] = true;
    }

    /// @inheritdoc IPredictionMarket
    function paymentToken() external view override returns (address token) {
        token = address(_paymentToken);
    }

    /// @inheritdoc IPredictionMarket
    function setPaymentToken(address token) external override onlyOwner {
        address sanitized = _requireNonZero(token, AddressField.PaymentToken);
        _paymentToken = IERC20(sanitized);
        emit PaymentTokenUpdated(sanitized);
    }

    /// @inheritdoc IPredictionMarket
    function setCreationAgent(address agent) external override onlyOwner {
        creationAgent = _requireNonZero(agent, AddressField.CreationAgent);
        _approvedTraders[creationAgent] = true;
        emit CreationAgentUpdated(agent);
    }

    /// @inheritdoc IPredictionMarket
    function setResolutionAgent(address agent) external override onlyOwner {
        resolutionAgent = _requireNonZero(agent, AddressField.ResolutionAgent);
        _approvedTraders[resolutionAgent] = true;
        emit ResolutionAgentUpdated(agent);
    }

    /// @inheritdoc IPredictionMarket
    function setFeeRecipient(address recipient) external override onlyOwner {
        feeRecipient = _requireNonZero(recipient, AddressField.FeeRecipient);
        emit FeeRecipientUpdated(recipient);
    }

    /// @inheritdoc IPredictionMarket
    function approvalAuthority() external view override returns (address authority) {
        authority = _approvalAuthority;
    }

    /// @inheritdoc IPredictionMarket
    function traderApprovalRequired() external view override returns (bool required) {
        required = _traderApprovalRequired;
    }

    /// @inheritdoc IPredictionMarket
    function isTraderApproved(address trader) external view override returns (bool approved) {
        approved = _approvedTraders[trader];
    }

    /// @inheritdoc IPredictionMarket
    function setApprovalAuthority(address authority) external override onlyOwner {
        address sanitized = _requireNonZero(authority, AddressField.ApprovalAuthority);
        _approvalAuthority = sanitized;
        _approvedTraders[sanitized] = true;
        emit TraderApprovalAuthorityUpdated(sanitized);
    }

    /// @inheritdoc IPredictionMarket
    function setRequireTraderApproval(bool required) external override onlyOwner {
        if (_traderApprovalRequired == required) {
            return;
        }
        _traderApprovalRequired = required;
        emit TraderApprovalRequirementUpdated(required);
    }

    /// @inheritdoc IPredictionMarket
    function setTraderApproval(address trader, bool approved) external override {
        address caller = _msgSender();
        if (caller != _approvalAuthority && caller != owner()) {
            revert Unauthorized(caller);
        }
        require(trader != address(0), ZeroAddress(AddressField.Trader));
        _approvedTraders[trader] = approved;
        emit TraderApprovalUpdated(trader, approved);
    }

    /// @inheritdoc IPredictionMarket
    function createMarket(MarketCreation calldata params)
        external
        override
        onlyCreationAgent
        returns (MarketId marketId)
    {
        require(bytes(params.questionURI).length != 0, EmptyQuestionURI());
        require(bytes(params.oracleURI).length != 0, EmptyOracleURI());
        require(params.openEpoch <= params.closeEpoch, InvalidEpochRange(params.openEpoch, params.closeEpoch));
        require(params.feeBps <= MAX_FEE_BPS, FeeTooHigh(params.feeBps, uint16(MAX_FEE_BPS)));

        uint256 nextId = ++_marketIdSequence;
        Market storage market = _markets[nextId];
        market.status = MarketStatus.Active;
        market.outcome = Outcome.Undefined;
        market.openEpoch = params.openEpoch;
        market.closeEpoch = params.closeEpoch;
        market.feeBps = params.feeBps;
        market.questionURI = params.questionURI;
        market.oracleURI = params.oracleURI;
        market.creator = _msgSender();

        marketId = MarketId.wrap(nextId);
        emit MarketCreated(
            marketId,
            _msgSender(),
            params.questionURI,
            params.oracleURI,
            params.openEpoch,
            params.closeEpoch,
            params.feeBps
        );
    }

    /// @inheritdoc IPredictionMarket
    function getMarket(MarketId marketId) external view override returns (MarketView memory marketView) {
        Market storage market = _getMarket(marketId);
        bool finalizable = market.resolvedAt != 0
            && !market.disputeActive
            && block.timestamp >= market.resolvedAt + disputeWindow;
        marketView = MarketView({
            status: market.status,
            outcome: market.outcome,
            finalizable: finalizable,
            openEpoch: market.openEpoch,
            closeEpoch: market.closeEpoch,
            feeBps: market.feeBps,
            questionURI: market.questionURI,
            oracleURI: market.oracleURI,
            resolutionURI: market.resolutionURI,
            resolutionEvidenceURI: market.resolutionEvidenceURI,
            creator: market.creator,
            resolver: market.resolver
        });
    }

    /// @inheritdoc IPredictionMarket
    function getDispute(MarketId marketId) external view override returns (Dispute memory dispute) {
        dispute = _disputes[MarketId.unwrap(marketId)];
    }

    /// @inheritdoc IPredictionMarket
    function getOrdersByOwner(address owner_)
        external
        view
        override
        returns (OrderView[] memory orders)
    {
        uint256[] storage orderIds = _ordersByOwner[owner_];
        orders = new OrderView[](orderIds.length);
        for (uint256 i = 0; i < orderIds.length; i++) {
            Order storage order = _orders[orderIds[i]];
            orders[i] = OrderView({
                orderId: OrderId.wrap(orderIds[i]),
                marketId: MarketId.wrap(order.marketKey),
                owner: order.owner,
                position: order.position,
                price: order.price,
                quantity: order.quantity,
                filled: order.filled,
                orderType: order.orderType,
                expirationEpoch: order.expirationEpoch,
                active: order.active
            });
        }
    }

    /// @inheritdoc IPredictionMarket
    function submitOrder(OrderSubmission calldata order)
        external
        override
        nonReentrant
        returns (OrderId orderId)
    {
        _enforceTraderApproval(_msgSender());

        Market storage market = _getMarket(order.marketId);
        require(market.status == MarketStatus.Active, MarketNotActive(order.marketId, market.status));
        require(
            block.timestamp >= market.openEpoch && block.timestamp <= market.closeEpoch,
            MarketClosed(order.marketId)
        );
        require(
            order.position == Outcome.Yes || order.position == Outcome.No,
            InvalidOutcome(order.marketId, order.position)
        );
        require(order.price > 0 && order.price < PRICE_SCALE, InvalidPrice(order.price));
        require(order.quantity > 0, InvalidQuantity(order.quantity));
        require(order.orderType == OrderType.GoodTilCancel, UnsupportedOrderType(order.orderType));
        require(
            order.expirationEpoch == 0 || order.expirationEpoch >= block.timestamp,
            InvalidExpiration(order.expirationEpoch)
        );

        uint256 stakeRequired = _stakeFor(order.position, order.price, order.quantity);
        _transferIn(_msgSender(), stakeRequired);

        uint256 nextOrderId = ++_orderIdSequence;
        address beneficiary = order.recipient == address(0) ? _msgSender() : order.recipient;
        _orders[nextOrderId] = Order({
            marketKey: MarketId.unwrap(order.marketId),
            owner: _msgSender(),
            beneficiary: beneficiary,
            position: order.position,
            price: order.price,
            quantity: order.quantity,
            filled: 0,
            orderType: order.orderType,
            expirationEpoch: order.expirationEpoch,
            active: true
        });
        _ordersByOwner[_msgSender()].push(nextOrderId);

        orderId = OrderId.wrap(nextOrderId);
        emit OrderPlaced(
            orderId,
            order.marketId,
            _msgSender(),
            order.position,
            order.price,
            order.quantity,
            order.orderType,
            order.expirationEpoch
        );
    }

    /// @inheritdoc IPredictionMarket
    function cancelOrder(OrderId orderId) external override nonReentrant {
        uint256 key = OrderId.unwrap(orderId);
        Order storage order = _orders[key];
        require(order.owner != address(0), UnknownOrder(orderId));
        require(order.active, OrderNotActive(orderId));
        require(order.owner == _msgSender(), Unauthorized(_msgSender()));

        uint128 remaining = order.quantity - order.filled;
        if (remaining > 0) {
            uint256 refund = _stakeFor(order.position, order.price, remaining);
            _transferOut(order.owner, refund);
        }
        order.active = false;

        emit OrderCancelled(orderId, MarketId.wrap(order.marketKey), order.owner, remaining);
    }

    /// @inheritdoc IPredictionMarket
    function fillOrder(OrderFill calldata fill)
        external
        override
        nonReentrant
        returns (uint256 cost, uint256 fee)
    {
        _enforceTraderApproval(_msgSender());

        uint256 key = OrderId.unwrap(fill.orderId);
        Order storage order = _orders[key];
        require(order.owner != address(0), UnknownOrder(fill.orderId));
        require(order.active, OrderNotActive(fill.orderId));
        if (_traderApprovalRequired && !_approvedTraders[order.owner]) {
            revert TraderNotApproved(order.owner);
        }

        Market storage market = _getMarket(MarketId.wrap(order.marketKey));
        require(market.status == MarketStatus.Active, MarketNotActive(MarketId.wrap(order.marketKey), market.status));
        require(
            block.timestamp >= market.openEpoch && block.timestamp <= market.closeEpoch,
            MarketClosed(MarketId.wrap(order.marketKey))
        );
        require(
            order.expirationEpoch == 0 || block.timestamp <= order.expirationEpoch,
            OrderExpired(fill.orderId, order.expirationEpoch)
        );
        require(fill.limitPrice > 0 && fill.limitPrice < PRICE_SCALE, InvalidPrice(fill.limitPrice));

        uint128 remaining = order.quantity - order.filled;
        require(fill.quantity > 0, InvalidQuantity(fill.quantity));
        require(fill.quantity <= remaining, Overfill(fill.orderId, fill.quantity, remaining));

        if (order.position == Outcome.Yes) {
            require(order.price >= fill.limitPrice, SlippageExceeded(fill.limitPrice, order.price));
        } else {
            require(order.price <= fill.limitPrice, SlippageExceeded(fill.limitPrice, order.price));
        }

        Outcome counterOutcome = _opposite(order.position);
        uint256 takerStake = _stakeFor(counterOutcome, order.price, fill.quantity);

        _transferIn(_msgSender(), takerStake);

        address makerBeneficiary = order.beneficiary;
        address takerBeneficiary = fill.recipient == address(0) ? _msgSender() : fill.recipient;

        _positions[order.marketKey][makerBeneficiary][uint8(order.position)] += fill.quantity;
        _positions[order.marketKey][takerBeneficiary][uint8(counterOutcome)] += fill.quantity;

        order.filled += fill.quantity;
        if (order.filled == order.quantity) {
            order.active = false;
        }

        market.totalCollateral += fill.quantity;

        cost = takerStake;
        fee = (uint256(fill.quantity) * market.feeBps) / MAX_FEE_BPS;

        emit OrderFilled(
            fill.orderId,
            MarketId.wrap(order.marketKey),
            order.owner,
            _msgSender(),
            fill.quantity,
            order.price,
            fee,
            takerBeneficiary
        );
    }

    /// @inheritdoc IPredictionMarket
    function resolveMarket(MarketId marketId, Resolution calldata resolution)
        external
        override
        onlyResolutionAgent
    {
        require(
            resolution.outcome == Outcome.Yes || resolution.outcome == Outcome.No,
            InvalidOutcome(marketId, resolution.outcome)
        );
        require(bytes(resolution.resolutionURI).length != 0, EmptyResolutionURI());
        require(bytes(resolution.evidenceURI).length != 0, EmptyEvidenceURI());

        Market storage market = _getMarket(marketId);
        require(market.status == MarketStatus.Active, MarketNotActive(marketId, market.status));
        require(block.timestamp >= market.closeEpoch, ResolveWindowNotReached(marketId, uint64(block.timestamp)));

        uint64 resolvedTimestamp = resolution.resolvedAt > 0 ? resolution.resolvedAt : uint64(block.timestamp);
        require(resolvedTimestamp >= market.closeEpoch, InvalidResolutionTimestamp(resolvedTimestamp, market.closeEpoch));

        market.status = MarketStatus.Resolved;
        market.outcome = resolution.outcome;
        market.resolver = _msgSender();
        market.resolvedAt = resolvedTimestamp;
        market.resolutionURI = resolution.resolutionURI;
        market.resolutionEvidenceURI = resolution.evidenceURI;
        market.disputeActive = false;
        delete _disputes[MarketId.unwrap(marketId)];

        emit MarketResolved(marketId, resolution.outcome, resolution.resolutionURI, resolution.evidenceURI, _msgSender());
    }

    /// @inheritdoc IPredictionMarket
    function disputeMarket(MarketId marketId, string calldata evidenceURI) external override nonReentrant {
        Market storage market = _getMarket(marketId);
        require(market.status == MarketStatus.Resolved, MarketNotActive(marketId, market.status));
        require(!market.disputeActive, DisputeActive(marketId));
        require(bytes(evidenceURI).length != 0, EmptyEvidenceURI());

        if (disputeBond > 0) {
            _transferIn(_msgSender(), disputeBond);
        }

        uint256 key = MarketId.unwrap(marketId);
        _disputes[key] = Dispute({
            evidenceURI: evidenceURI,
            bondAmount: disputeBond,
            openedAt: uint64(block.timestamp),
            disputant: _msgSender()
        });
        market.disputeActive = true;
        market.status = MarketStatus.Disputed;

        emit MarketDisputed(marketId, _msgSender(), evidenceURI, disputeBond);
    }

    /// @inheritdoc IPredictionMarket
    function finalizeMarket(MarketId marketId) external override onlyOwner {
        Market storage market = _getMarket(marketId);
        require(
            market.status == MarketStatus.Resolved || market.status == MarketStatus.Disputed,
            MarketNotActive(marketId, market.status)
        );
        require(market.resolvedAt != 0, MarketUnresolved());
        require(block.timestamp >= market.resolvedAt + disputeWindow, DisputeWindowClosed(marketId));
        require(market.outcome != Outcome.Undefined, InvalidOutcome(marketId, market.outcome));

        Dispute memory dispute = _disputes[MarketId.unwrap(marketId)];
        if (dispute.disputant != address(0) && dispute.bondAmount > 0) {
            _transferOut(dispute.disputant, dispute.bondAmount);
        }
        delete _disputes[MarketId.unwrap(marketId)];

        market.status = MarketStatus.Finalized;
        market.disputeActive = false;

        emit MarketFinalized(marketId, market.outcome, market.resolutionURI);
    }

    /// @inheritdoc IPredictionMarket
    function claimPayout(MarketId marketId, Outcome position, address recipient)
        external
        override
        nonReentrant
        returns (uint256 amount)
    {
        Market storage market = _getMarket(marketId);
        require(market.status == MarketStatus.Finalized, MarketNotActive(marketId, market.status));
        require(position == market.outcome, InvalidOutcome(marketId, position));
        require(!_hasClaimed[MarketId.unwrap(marketId)][_msgSender()], AlreadyClaimed(marketId, _msgSender()));

        uint128 shares = _positions[MarketId.unwrap(marketId)][_msgSender()][uint8(position)];
        require(shares != 0, NoPosition(marketId, position, _msgSender()));

        _positions[MarketId.unwrap(marketId)][_msgSender()][uint8(position)] = 0;
        _hasClaimed[MarketId.unwrap(marketId)][_msgSender()] = true;

        uint256 payout = shares;
        uint256 fee = (payout * market.feeBps) / MAX_FEE_BPS;
        amount = payout - fee;

        address target = recipient == address(0) ? _msgSender() : recipient;

        if (fee > 0) {
            _transferOut(feeRecipient, fee);
        }
        _transferOut(target, amount);

        emit PayoutClaimed(marketId, _msgSender(), position, payout);
    }

    function _getMarket(MarketId marketId) private view returns (Market storage) {
        Market storage market = _markets[MarketId.unwrap(marketId)];
        require(market.creator != address(0), UnknownMarket(marketId));
        return market;
    }

    function _stakeFor(Outcome position, uint128 price, uint128 quantity) private pure returns (uint256) {
        uint256 qty = uint256(quantity);
        if (position == Outcome.Yes) {
            return (uint256(price) * qty) / PRICE_SCALE;
        }
        if (position == Outcome.No) {
            return (uint256(PRICE_SCALE - price) * qty) / PRICE_SCALE;
        }
        return 0;
    }

    function _opposite(Outcome outcome) private pure returns (Outcome) {
        if (outcome == Outcome.Yes) {
            return Outcome.No;
        }
        if (outcome == Outcome.No) {
            return Outcome.Yes;
        }
        return Outcome.Undefined;
    }

    function _enforceTraderApproval(address trader) private view {
        if (_traderApprovalRequired && !_approvedTraders[trader]) {
            revert TraderNotApproved(trader);
        }
    }

    function _transferIn(address from, uint256 amount) private {
        if (amount == 0) return;
        bool ok = _paymentToken.transferFrom(from, address(this), amount);
        require(ok, InsufficientAvailableBalance(from, amount, _paymentToken.balanceOf(from)));
    }

    function _transferOut(address to, uint256 amount) private {
        if (amount == 0) return;
        uint256 balance = _paymentToken.balanceOf(address(this));
        require(balance >= amount, InsufficientAvailableBalance(address(this), amount, balance));
        bool ok = _paymentToken.transfer(to, amount);
        require(ok, InsufficientAvailableBalance(address(this), amount, balance));
    }

    function _requireNonZero(address account, AddressField field) private pure returns (address) {
        require(account != address(0), ZeroAddress(field));
        return account;
    }

    function _checkOwner() internal view override {
        require(owner() == _msgSender(), Unauthorized(_msgSender()));
    }
}

