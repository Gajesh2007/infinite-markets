// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PredictionMarket.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract PredictionMarketTest is Test {
    MockERC20 collateral;
    PredictionMarket market;

    address internal constant CREATION_AGENT = address(0x1);
    address internal constant RESOLUTION_AGENT = address(0x2);
    address internal constant TRADER_A = address(0x3);
    address internal constant TRADER_B = address(0x4);
    address internal constant TRADER_C = address(0x5);
    address internal constant FEE_RECIPIENT = address(0x6);
    address internal constant ALT_APPROVAL_AUTHORITY = address(0x7);

    uint64 internal constant DISPUTE_WINDOW = 1 hours;
    uint256 internal constant DISPUTE_BOND = 5_000_000;

    IPredictionMarket.MarketId private marketId;

    function setUp() public {
        collateral = new MockERC20("Mock USD", "mUSD", 6);
        market = new PredictionMarket(
            address(this),
            CREATION_AGENT,
            RESOLUTION_AGENT,
            address(collateral),
            FEE_RECIPIENT,
            DISPUTE_WINDOW,
            DISPUTE_BOND
        );

        collateral.mint(TRADER_A, 1_000_000_000);
        collateral.mint(TRADER_B, 1_000_000_000);
        collateral.mint(TRADER_C, 1_000_000_000);
        collateral.mint(address(this), 1_000_000_000);

        vm.prank(TRADER_A);
        collateral.approve(address(market), type(uint256).max);
        vm.prank(TRADER_B);
        collateral.approve(address(market), type(uint256).max);
        vm.prank(TRADER_C);
        collateral.approve(address(market), type(uint256).max);
        collateral.approve(address(market), type(uint256).max);

        marketId = _createDefaultMarket(100);
    }

    /// @notice Happy path: Maker submits YES order, taker fills it, market resolves YES, both claim.
    function testSubmitAndFillLifecycle() public {
        uint256 makerStart = collateral.balanceOf(TRADER_A);
        uint256 takerStart = collateral.balanceOf(TRADER_B);

        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 600_000,
            quantity: 100_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        IPredictionMarket.OrderId orderId = market.submitOrder(submission);

        uint256 makerEscrow = (uint256(submission.price) * submission.quantity) / 1_000_000;
        assertEq(collateral.balanceOf(TRADER_A), makerStart - makerEscrow, "maker escrow debited");
        assertEq(collateral.balanceOf(address(market)), makerEscrow, "market holds maker escrow");

        IPredictionMarket.OrderFill memory fill = IPredictionMarket.OrderFill({
            orderId: orderId,
            limitPrice: 600_000,
            quantity: 50_000_000,
            recipient: address(0)
        });

        vm.prank(TRADER_B);
        (uint256 cost,) = market.fillOrder(fill);
        uint256 takerStakeFirst = (1_000_000 - submission.price) * fill.quantity / 1_000_000;
        assertEq(cost, takerStakeFirst, "fill cost expected");
        assertEq(collateral.balanceOf(TRADER_B), takerStart - takerStakeFirst, "taker debited");

        IPredictionMarket.OrderFill memory fillSecond = IPredictionMarket.OrderFill({
            orderId: orderId,
            limitPrice: 600_000,
            quantity: 50_000_000,
            recipient: address(0)
        });
        vm.prank(TRADER_B);
        market.fillOrder(fillSecond);

        assertEq(collateral.balanceOf(address(market)), makerEscrow + takerStakeFirst * 2, "both stakes escrowed");

        _warpToClose();

        IPredictionMarket.Resolution memory resolution = IPredictionMarket.Resolution({
            outcome: IPredictionMarket.Outcome.Yes,
            resolutionURI: "ipfs://resolution/yes",
            evidenceURI: "ipfs://evidence/yes",
            resolvedAt: uint64(block.timestamp)
        });

        vm.prank(RESOLUTION_AGENT);
        market.resolveMarket(marketId, resolution);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        market.finalizeMarket(marketId);

        uint256 makerBalanceBeforeClaim = collateral.balanceOf(TRADER_A);
        uint256 feeRecipientBefore = collateral.balanceOf(FEE_RECIPIENT);

        vm.prank(TRADER_A);
        uint256 payout = market.claimPayout(marketId, IPredictionMarket.Outcome.Yes, address(0));
        assertEq(payout, 99_000_000, "net payout matches fee deduction");

        assertEq(collateral.balanceOf(TRADER_A), makerBalanceBeforeClaim + payout, "maker credited");
        IPredictionMarket.MarketView memory viewData = market.getMarket(marketId);
        uint256 expectedFee = (submission.quantity * viewData.feeBps) / 10_000;
        assertEq(collateral.balanceOf(FEE_RECIPIENT), feeRecipientBefore + expectedFee, "fee forwarded");

        vm.prank(TRADER_B);
        vm.expectRevert(abi.encodeWithSelector(IPredictionMarket.InvalidOutcome.selector, marketId, IPredictionMarket.Outcome.No));
        market.claimPayout(marketId, IPredictionMarket.Outcome.No, address(0));
    }

    /// @notice Cancelling an unfilled order returns full escrow.
    function testCancelRestoresEscrow() public {
        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.No,
            price: 400_000,
            quantity: 80_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        IPredictionMarket.OrderId orderId = market.submitOrder(submission);

        vm.prank(TRADER_A);
        market.cancelOrder(orderId);

        assertEq(collateral.balanceOf(TRADER_A), 1_000_000_000, "escrow returned");
        assertEq(collateral.balanceOf(address(market)), 0, "contract emptied");
    }

    /// @notice Orders submitted before market opens revert.
    function testPreOpenOrderRejected() public {
        IPredictionMarket.MarketCreation memory params = IPredictionMarket.MarketCreation({
            questionURI: "ipfs://future-market",
            oracleURI: "https://example.com/oracle",
            openEpoch: uint64(block.timestamp + 1 days),
            closeEpoch: uint64(block.timestamp + 2 days),
            feeBps: 100
        });

        vm.prank(CREATION_AGENT);
        IPredictionMarket.MarketId futureMarketId = market.createMarket(params);

        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: futureMarketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 500_000,
            quantity: 10_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        vm.expectRevert(abi.encodeWithSelector(IPredictionMarket.MarketClosed.selector, futureMarketId));
        market.submitOrder(submission);
    }

    /// @notice Resolving before market close is blocked.
    function testResolveBeforeCloseBlocked() public {
        IPredictionMarket.Resolution memory resolution = IPredictionMarket.Resolution({
            outcome: IPredictionMarket.Outcome.Yes,
            resolutionURI: "ipfs://early",
            evidenceURI: "ipfs://evidence",
            resolvedAt: uint64(block.timestamp)
        });

        vm.prank(RESOLUTION_AGENT);
        vm.expectRevert();
        market.resolveMarket(marketId, resolution);
    }

    /// @notice Slippage guard prevents fill when limit price is exceeded.
    function testSlippageGuard() public {
        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 500_000,
            quantity: 10_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });
        vm.prank(TRADER_A);
        IPredictionMarket.OrderId orderId = market.submitOrder(submission);

        IPredictionMarket.OrderFill memory fill = IPredictionMarket.OrderFill({
            orderId: orderId,
            limitPrice: 510_000,
            quantity: 10_000_000,
            recipient: address(0)
        });

        vm.prank(TRADER_B);
        vm.expectRevert(abi.encodeWithSelector(IPredictionMarket.SlippageExceeded.selector, 510_000, 500_000));
        market.fillOrder(fill);
    }

    /// @notice Dispute bond is escrowed and returned after finalization.
    function testDisputeRoundsTripBond() public {
        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 500_000,
            quantity: 10_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        IPredictionMarket.OrderId orderId = market.submitOrder(submission);

        IPredictionMarket.OrderFill memory fill = IPredictionMarket.OrderFill({
            orderId: orderId,
            limitPrice: 500_000,
            quantity: 10_000_000,
            recipient: address(0)
        });
        vm.prank(TRADER_B);
        market.fillOrder(fill);

        _warpToClose();
        IPredictionMarket.Resolution memory resolution = IPredictionMarket.Resolution({
            outcome: IPredictionMarket.Outcome.Yes,
            resolutionURI: "ipfs://resolution",
            evidenceURI: "ipfs://evidence",
            resolvedAt: uint64(block.timestamp)
        });
        vm.prank(RESOLUTION_AGENT);
        market.resolveMarket(marketId, resolution);

        uint256 disputantStart = collateral.balanceOf(TRADER_B);
        vm.prank(TRADER_B);
        market.disputeMarket(marketId, "ipfs://dispute");

        assertEq(collateral.balanceOf(TRADER_B), disputantStart - DISPUTE_BOND, "bond escrowed");

        vm.expectRevert();
        market.finalizeMarket(marketId);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        market.finalizeMarket(marketId);
        assertEq(collateral.balanceOf(TRADER_B), disputantStart, "bond returned on finalize");
    }

    /// @notice Only creation agent can call createMarket.
    function testOnlyCreationAgentCanCreateMarket() public {
        IPredictionMarket.MarketCreation memory params = IPredictionMarket.MarketCreation({
            questionURI: "ipfs://unauthorized",
            oracleURI: "https://example.com/oracle",
            openEpoch: uint64(block.timestamp),
            closeEpoch: uint64(block.timestamp + 1 days),
            feeBps: 100
        });

        vm.prank(TRADER_A);
        vm.expectRevert(abi.encodeWithSelector(IPredictionMarket.Unauthorized.selector, TRADER_A));
        market.createMarket(params);
    }

    /// @notice Owner-only setters revert when called by non-owner.
    function testOwnerOnlySetters() public {
        vm.prank(TRADER_A);
        vm.expectRevert();
        market.setPaymentToken(address(0x999));

        vm.prank(TRADER_A);
        vm.expectRevert();
        market.setCreationAgent(address(0x888));

        vm.prank(TRADER_A);
        vm.expectRevert();
        market.setResolutionAgent(address(0x777));

        vm.prank(TRADER_A);
        vm.expectRevert();
        market.setFeeRecipient(address(0x666));
    }

    /// @notice Enabling trader approval enforces allowlist for makers and takers.
    function testTraderApprovalRequirementEnforced() public {
        assertFalse(market.traderApprovalRequired());

        vm.prank(address(this));
        market.setRequireTraderApproval(true);
        assertTrue(market.traderApprovalRequired());
        assertEq(market.approvalAuthority(), address(this));

        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 500_000,
            quantity: 10_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        vm.expectRevert(abi.encodeWithSelector(IPredictionMarket.TraderNotApproved.selector, TRADER_A));
        market.submitOrder(submission);

        vm.prank(address(this));
        market.setTraderApproval(TRADER_A, true);
        assertTrue(market.isTraderApproved(TRADER_A));

        vm.prank(TRADER_A);
        IPredictionMarket.OrderId orderId = market.submitOrder(submission);

        IPredictionMarket.OrderFill memory fill = IPredictionMarket.OrderFill({
            orderId: orderId,
            limitPrice: 500_000,
            quantity: 10_000_000,
            recipient: address(0)
        });

        vm.prank(TRADER_B);
        vm.expectRevert(abi.encodeWithSelector(IPredictionMarket.TraderNotApproved.selector, TRADER_B));
        market.fillOrder(fill);

        vm.prank(address(this));
        market.setTraderApproval(TRADER_B, true);
        assertTrue(market.isTraderApproved(TRADER_B));

        vm.prank(TRADER_B);
        market.fillOrder(fill);
    }

    /// @notice Approval authority can be rotated and is the only party (besides owner) allowed to approve traders.
    function testApprovalAuthorityRotation() public {
        vm.prank(address(this));
        market.setApprovalAuthority(ALT_APPROVAL_AUTHORITY);
        assertEq(market.approvalAuthority(), ALT_APPROVAL_AUTHORITY);
        assertTrue(market.isTraderApproved(ALT_APPROVAL_AUTHORITY));

        vm.prank(TRADER_B);
        vm.expectRevert(abi.encodeWithSelector(IPredictionMarket.Unauthorized.selector, TRADER_B));
        market.setTraderApproval(TRADER_A, true);

        vm.prank(ALT_APPROVAL_AUTHORITY);
        market.setTraderApproval(TRADER_A, true);
        assertTrue(market.isTraderApproved(TRADER_A));

        vm.prank(address(this));
        market.setTraderApproval(TRADER_B, true);
        assertTrue(market.isTraderApproved(TRADER_B));
    }

    /// @notice Market creation validates inputs.
    function testMarketCreationValidation() public {
        vm.startPrank(CREATION_AGENT);

        IPredictionMarket.MarketCreation memory params = IPredictionMarket.MarketCreation({
            questionURI: "",
            oracleURI: "https://example.com/oracle",
            openEpoch: uint64(block.timestamp),
            closeEpoch: uint64(block.timestamp + 1 days),
            feeBps: 100
        });
        vm.expectRevert();
        market.createMarket(params);

        params.questionURI = "ipfs://question";
        params.oracleURI = "";
        vm.expectRevert();
        market.createMarket(params);

        params.oracleURI = "https://example.com/oracle";
        params.feeBps = 10_001;
        vm.expectRevert();
        market.createMarket(params);

        vm.stopPrank();
    }

    /// @notice Dispute can only be lodged on a resolved market.
    function testDisputeRequiresResolvedMarket() public {
        vm.prank(TRADER_A);
        vm.expectRevert();
        market.disputeMarket(marketId, "ipfs://dispute");

        _warpToClose();
        IPredictionMarket.Resolution memory resolution = IPredictionMarket.Resolution({
            outcome: IPredictionMarket.Outcome.Yes,
            resolutionURI: "ipfs://resolution",
            evidenceURI: "ipfs://evidence",
            resolvedAt: uint64(block.timestamp)
        });
        vm.prank(RESOLUTION_AGENT);
        market.resolveMarket(marketId, resolution);

        vm.prank(TRADER_A);
        market.disputeMarket(marketId, "ipfs://dispute");
    }

    /// @notice Finalization before dispute window reverts; double-claim is blocked.
    function testFinalizeAndClaimRestrictions() public {
        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 500_000,
            quantity: 10_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });
        vm.prank(TRADER_A);
        IPredictionMarket.OrderId orderId = market.submitOrder(submission);

        IPredictionMarket.OrderFill memory fill = IPredictionMarket.OrderFill({
            orderId: orderId,
            limitPrice: 500_000,
            quantity: 10_000_000,
            recipient: address(0)
        });

        vm.prank(TRADER_B);
        market.fillOrder(fill);

        _warpToClose();
        IPredictionMarket.Resolution memory resolution = IPredictionMarket.Resolution({
            outcome: IPredictionMarket.Outcome.Yes,
            resolutionURI: "ipfs://resolution",
            evidenceURI: "ipfs://evidence",
            resolvedAt: uint64(block.timestamp)
        });
        vm.prank(RESOLUTION_AGENT);
        market.resolveMarket(marketId, resolution);

        vm.expectRevert();
        market.finalizeMarket(marketId);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        market.finalizeMarket(marketId);

        vm.prank(TRADER_A);
        market.claimPayout(marketId, IPredictionMarket.Outcome.Yes, address(0));

        vm.prank(TRADER_A);
        vm.expectRevert();
        market.claimPayout(marketId, IPredictionMarket.Outcome.Yes, address(0));
    }

    /// @notice Partial fills update order state correctly.
    function testPartialFillUpdatesOrderState() public {
        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 600_000,
            quantity: 100_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        IPredictionMarket.OrderId orderId = market.submitOrder(submission);

        IPredictionMarket.OrderView[] memory orders = market.getOrdersByOwner(TRADER_A);
        assertEq(orders.length, 1, "one order");
        assertEq(orders[0].filled, 0, "unfilled initially");
        assertTrue(orders[0].active, "active initially");

        IPredictionMarket.OrderFill memory fill = IPredictionMarket.OrderFill({
            orderId: orderId,
            limitPrice: 600_000,
            quantity: 30_000_000,
            recipient: address(0)
        });

        vm.prank(TRADER_B);
        market.fillOrder(fill);

        orders = market.getOrdersByOwner(TRADER_A);
        assertEq(orders[0].filled, 30_000_000, "partial fill recorded");
        assertTrue(orders[0].active, "still active");

        fill.quantity = 70_000_000;
        vm.prank(TRADER_B);
        market.fillOrder(fill);

        orders = market.getOrdersByOwner(TRADER_A);
        assertEq(orders[0].filled, 100_000_000, "fully filled");
        assertFalse(orders[0].active, "inactive after complete fill");
    }

    /// @notice Overfilling an order reverts.
    function testOverfillReverts() public {
        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 500_000,
            quantity: 10_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        IPredictionMarket.OrderId orderId = market.submitOrder(submission);

        IPredictionMarket.OrderFill memory fill = IPredictionMarket.OrderFill({
            orderId: orderId,
            limitPrice: 500_000,
            quantity: 10_000_001,
            recipient: address(0)
        });

        vm.prank(TRADER_B);
        vm.expectRevert();
        market.fillOrder(fill);
    }

    /// @notice Cancelling a non-existent order reverts.
    function testCancelNonExistentOrderReverts() public {
        vm.prank(TRADER_A);
        vm.expectRevert();
        market.cancelOrder(IPredictionMarket.OrderId.wrap(9999));
    }

    /// @notice Cancelling someone else's order reverts.
    function testCancelUnauthorizedOrderReverts() public {
        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 500_000,
            quantity: 10_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        IPredictionMarket.OrderId orderId = market.submitOrder(submission);

        vm.prank(TRADER_B);
        vm.expectRevert(abi.encodeWithSelector(IPredictionMarket.Unauthorized.selector, TRADER_B));
        market.cancelOrder(orderId);
    }

    /// @notice Cancelling a partially filled order returns remaining escrow.
    function testCancelPartiallyFilledOrder() public {
        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 600_000,
            quantity: 100_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        IPredictionMarket.OrderId orderId = market.submitOrder(submission);

        uint256 balanceAfterSubmit = collateral.balanceOf(TRADER_A);

        IPredictionMarket.OrderFill memory fill = IPredictionMarket.OrderFill({
            orderId: orderId,
            limitPrice: 600_000,
            quantity: 40_000_000,
            recipient: address(0)
        });

        vm.prank(TRADER_B);
        market.fillOrder(fill);

        vm.prank(TRADER_A);
        market.cancelOrder(orderId);

        uint256 remainingEscrow = (uint256(submission.price) * (submission.quantity - fill.quantity)) / 1_000_000;
        assertEq(collateral.balanceOf(TRADER_A), balanceAfterSubmit + remainingEscrow, "remaining escrow returned");
    }

    /// @notice Order with zero price reverts.
    function testZeroPriceOrderReverts() public {
        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 0,
            quantity: 10_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        vm.expectRevert();
        market.submitOrder(submission);
    }

    /// @notice Order with price >= 1e6 reverts.
    function testPriceAtOrAboveScaleReverts() public {
        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 1_000_000,
            quantity: 10_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        vm.expectRevert();
        market.submitOrder(submission);

        submission.price = 1_000_001;
        vm.prank(TRADER_A);
        vm.expectRevert();
        market.submitOrder(submission);
    }

    /// @notice Order with zero quantity reverts.
    function testZeroQuantityOrderReverts() public {
        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 500_000,
            quantity: 0,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        vm.expectRevert();
        market.submitOrder(submission);
    }

    /// @notice Order with Undefined outcome reverts.
    function testUndefinedOutcomeOrderReverts() public {
        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Undefined,
            price: 500_000,
            quantity: 10_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        vm.expectRevert();
        market.submitOrder(submission);
    }

    /// @notice Filling with zero quantity reverts.
    function testFillZeroQuantityReverts() public {
        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 500_000,
            quantity: 10_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        IPredictionMarket.OrderId orderId = market.submitOrder(submission);

        IPredictionMarket.OrderFill memory fill = IPredictionMarket.OrderFill({
            orderId: orderId,
            limitPrice: 500_000,
            quantity: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_B);
        vm.expectRevert();
        market.fillOrder(fill);
    }

    /// @notice Expired order rejects fills with the OrderExpired error.
    function testExpiredOrderCannotBeFilled() public {
        uint64 expiration = uint64(block.timestamp + 30 minutes);

        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 500_000,
            quantity: 10_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: expiration,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        IPredictionMarket.OrderId orderId = market.submitOrder(submission);

        vm.warp(expiration + 1);

        IPredictionMarket.OrderFill memory fill = IPredictionMarket.OrderFill({
            orderId: orderId,
            limitPrice: 500_000,
            quantity: 10_000_000,
            recipient: address(0)
        });

        vm.prank(TRADER_B);
        vm.expectRevert(abi.encodeWithSelector(IPredictionMarket.OrderExpired.selector, orderId, expiration));
        market.fillOrder(fill);
    }


    /// @notice Order expiration can be zero (no expiration).
    function testZeroExpirationAllowed() public {
        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 500_000,
            quantity: 10_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        market.submitOrder(submission);
    }

    /// @notice Market with inverted epochs (open > close) reverts.
    function testInvertedEpochsRevert() public {
        IPredictionMarket.MarketCreation memory params = IPredictionMarket.MarketCreation({
            questionURI: "ipfs://invalid",
            oracleURI: "https://example.com/oracle",
            openEpoch: uint64(block.timestamp + 2 days),
            closeEpoch: uint64(block.timestamp + 1 days),
            feeBps: 100
        });

        vm.prank(CREATION_AGENT);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPredictionMarket.InvalidEpochRange.selector,
                params.openEpoch,
                params.closeEpoch
            )
        );
        market.createMarket(params);
    }

    /// @notice Claiming payout on unfinalized market reverts.
    function testClaimPayoutOnUnfinalizedMarketReverts() public {
        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 500_000,
            quantity: 10_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        market.submitOrder(submission);

        _warpToClose();

        IPredictionMarket.Resolution memory resolution = IPredictionMarket.Resolution({
            outcome: IPredictionMarket.Outcome.Yes,
            resolutionURI: "ipfs://resolution",
            evidenceURI: "ipfs://evidence",
            resolvedAt: uint64(block.timestamp)
        });

        vm.prank(RESOLUTION_AGENT);
        market.resolveMarket(marketId, resolution);

        vm.prank(TRADER_A);
        vm.expectRevert();
        market.claimPayout(marketId, IPredictionMarket.Outcome.Yes, address(0));
    }

    /// @notice Claiming with zero position reverts.
    function testClaimPayoutWithZeroPositionReverts() public {
        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 500_000,
            quantity: 10_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        market.submitOrder(submission);

        _warpToClose();

        IPredictionMarket.Resolution memory resolution = IPredictionMarket.Resolution({
            outcome: IPredictionMarket.Outcome.Yes,
            resolutionURI: "ipfs://resolution",
            evidenceURI: "ipfs://evidence",
            resolvedAt: uint64(block.timestamp)
        });

        vm.prank(RESOLUTION_AGENT);
        market.resolveMarket(marketId, resolution);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        market.finalizeMarket(marketId);

        vm.prank(TRADER_C);
        vm.expectRevert();
        market.claimPayout(marketId, IPredictionMarket.Outcome.Yes, address(0));
    }

    /// @notice Multiple traders can claim independent positions.
    function testMultipleTradersClaim() public {
        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 600_000,
            quantity: 50_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        IPredictionMarket.OrderId orderId1 = market.submitOrder(submission);

        submission.quantity = 30_000_000;
        vm.prank(TRADER_C);
        IPredictionMarket.OrderId orderId2 = market.submitOrder(submission);

        IPredictionMarket.OrderFill memory fill1 = IPredictionMarket.OrderFill({
            orderId: orderId1,
            limitPrice: 600_000,
            quantity: 50_000_000,
            recipient: address(0)
        });

        vm.prank(TRADER_B);
        market.fillOrder(fill1);

        IPredictionMarket.OrderFill memory fill2 = IPredictionMarket.OrderFill({
            orderId: orderId2,
            limitPrice: 600_000,
            quantity: 30_000_000,
            recipient: address(0)
        });

        vm.prank(TRADER_B);
        market.fillOrder(fill2);

        _warpToClose();

        IPredictionMarket.Resolution memory resolution = IPredictionMarket.Resolution({
            outcome: IPredictionMarket.Outcome.Yes,
            resolutionURI: "ipfs://resolution",
            evidenceURI: "ipfs://evidence",
            resolvedAt: uint64(block.timestamp)
        });

        vm.prank(RESOLUTION_AGENT);
        market.resolveMarket(marketId, resolution);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        market.finalizeMarket(marketId);

        uint256 balanceABefore = collateral.balanceOf(TRADER_A);
        uint256 balanceCBefore = collateral.balanceOf(TRADER_C);

        vm.prank(TRADER_A);
        uint256 payoutA = market.claimPayout(marketId, IPredictionMarket.Outcome.Yes, address(0));

        vm.prank(TRADER_C);
        uint256 payoutC = market.claimPayout(marketId, IPredictionMarket.Outcome.Yes, address(0));

        assertEq(collateral.balanceOf(TRADER_A), balanceABefore + payoutA, "A credited");
        assertEq(collateral.balanceOf(TRADER_C), balanceCBefore + payoutC, "C credited");
        assertTrue(payoutA > 0, "A payout non-zero");
        assertTrue(payoutC > 0, "C payout non-zero");
    }

    /// @notice Resolution with empty URI reverts.
    function testResolutionWithEmptyURIReverts() public {
        _warpToClose();

        IPredictionMarket.Resolution memory resolution = IPredictionMarket.Resolution({
            outcome: IPredictionMarket.Outcome.Yes,
            resolutionURI: "",
            evidenceURI: "ipfs://evidence",
            resolvedAt: uint64(block.timestamp)
        });

        vm.prank(RESOLUTION_AGENT);
        vm.expectRevert();
        market.resolveMarket(marketId, resolution);

        resolution.resolutionURI = "ipfs://resolution";
        resolution.evidenceURI = "";

        vm.prank(RESOLUTION_AGENT);
        vm.expectRevert();
        market.resolveMarket(marketId, resolution);
    }

    /// @notice Dispute with empty evidence URI reverts.
    function testDisputeWithEmptyEvidenceURIReverts() public {
        _warpToClose();

        IPredictionMarket.Resolution memory resolution = IPredictionMarket.Resolution({
            outcome: IPredictionMarket.Outcome.Yes,
            resolutionURI: "ipfs://resolution",
            evidenceURI: "ipfs://evidence",
            resolvedAt: uint64(block.timestamp)
        });

        vm.prank(RESOLUTION_AGENT);
        market.resolveMarket(marketId, resolution);

        vm.prank(TRADER_A);
        vm.expectRevert();
        market.disputeMarket(marketId, "");
    }

    /// @notice Double-dispute on same market reverts.
    function testDoubleDisputeReverts() public {
        _warpToClose();

        IPredictionMarket.Resolution memory resolution = IPredictionMarket.Resolution({
            outcome: IPredictionMarket.Outcome.Yes,
            resolutionURI: "ipfs://resolution",
            evidenceURI: "ipfs://evidence",
            resolvedAt: uint64(block.timestamp)
        });

        vm.prank(RESOLUTION_AGENT);
        market.resolveMarket(marketId, resolution);

        vm.prank(TRADER_A);
        market.disputeMarket(marketId, "ipfs://dispute");

        vm.prank(TRADER_B);
        vm.expectRevert();
        market.disputeMarket(marketId, "ipfs://dispute2");
    }

    /// @notice Non-owner cannot finalize market.
    function testNonOwnerCannotFinalizeMarket() public {
        _warpToClose();

        IPredictionMarket.Resolution memory resolution = IPredictionMarket.Resolution({
            outcome: IPredictionMarket.Outcome.Yes,
            resolutionURI: "ipfs://resolution",
            evidenceURI: "ipfs://evidence",
            resolvedAt: uint64(block.timestamp)
        });

        vm.prank(RESOLUTION_AGENT);
        market.resolveMarket(marketId, resolution);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        vm.prank(TRADER_A);
        vm.expectRevert();
        market.finalizeMarket(marketId);
    }

    /// @notice Recipient parameter correctly routes position tokens on order submission.
    function testOrderRecipientRoutesPositionTokens() public {
        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 500_000,
            quantity: 10_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: TRADER_C
        });

        vm.prank(TRADER_A);
        IPredictionMarket.OrderId orderId = market.submitOrder(submission);

        IPredictionMarket.OrderFill memory fill = IPredictionMarket.OrderFill({
            orderId: orderId,
            limitPrice: 500_000,
            quantity: 10_000_000,
            recipient: address(0)
        });

        vm.prank(TRADER_B);
        market.fillOrder(fill);

        _warpToClose();

        IPredictionMarket.Resolution memory resolution = IPredictionMarket.Resolution({
            outcome: IPredictionMarket.Outcome.Yes,
            resolutionURI: "ipfs://resolution",
            evidenceURI: "ipfs://evidence",
            resolvedAt: uint64(block.timestamp)
        });

        vm.prank(RESOLUTION_AGENT);
        market.resolveMarket(marketId, resolution);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        market.finalizeMarket(marketId);

        vm.prank(TRADER_C);
        uint256 payout = market.claimPayout(marketId, IPredictionMarket.Outcome.Yes, address(0));
        assertTrue(payout > 0, "beneficiary received position");
    }

    /// @notice Fill recipient parameter correctly routes position tokens on fill.
    function testFillRecipientRoutesPositionTokens() public {
        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 500_000,
            quantity: 10_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        IPredictionMarket.OrderId orderId = market.submitOrder(submission);

        IPredictionMarket.OrderFill memory fill = IPredictionMarket.OrderFill({
            orderId: orderId,
            limitPrice: 500_000,
            quantity: 10_000_000,
            recipient: TRADER_C
        });

        vm.prank(TRADER_B);
        market.fillOrder(fill);

        _warpToClose();

        IPredictionMarket.Resolution memory resolution = IPredictionMarket.Resolution({
            outcome: IPredictionMarket.Outcome.No,
            resolutionURI: "ipfs://resolution",
            evidenceURI: "ipfs://evidence",
            resolvedAt: uint64(block.timestamp)
        });

        vm.prank(RESOLUTION_AGENT);
        market.resolveMarket(marketId, resolution);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        market.finalizeMarket(marketId);

        vm.prank(TRADER_C);
        uint256 payout = market.claimPayout(marketId, IPredictionMarket.Outcome.No, address(0));
        assertTrue(payout > 0, "fill recipient received position");
    }

    /// @notice Claim payout recipient parameter routes funds correctly.
    function testClaimPayoutRecipientRoutesFunds() public {
        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 500_000,
            quantity: 10_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        IPredictionMarket.OrderId orderId = market.submitOrder(submission);

        IPredictionMarket.OrderFill memory fill = IPredictionMarket.OrderFill({
            orderId: orderId,
            limitPrice: 500_000,
            quantity: 10_000_000,
            recipient: address(0)
        });

        vm.prank(TRADER_B);
        market.fillOrder(fill);

        _warpToClose();

        IPredictionMarket.Resolution memory resolution = IPredictionMarket.Resolution({
            outcome: IPredictionMarket.Outcome.Yes,
            resolutionURI: "ipfs://resolution",
            evidenceURI: "ipfs://evidence",
            resolvedAt: uint64(block.timestamp)
        });

        vm.prank(RESOLUTION_AGENT);
        market.resolveMarket(marketId, resolution);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        market.finalizeMarket(marketId);

        uint256 balanceCBefore = collateral.balanceOf(TRADER_C);

        vm.prank(TRADER_A);
        uint256 payout = market.claimPayout(marketId, IPredictionMarket.Outcome.Yes, TRADER_C);

        assertEq(collateral.balanceOf(TRADER_C), balanceCBefore + payout, "claim recipient credited");
    }


    /// @notice Orders after market close are rejected.
    function testOrdersAfterMarketCloseRejected() public {
        vm.warp(block.timestamp + 2 days);

        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 500_000,
            quantity: 10_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        vm.expectRevert();
        market.submitOrder(submission);
    }

    /// @notice Fills after market close are rejected.
    function testFillsAfterMarketCloseRejected() public {
        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 500_000,
            quantity: 10_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        IPredictionMarket.OrderId orderId = market.submitOrder(submission);

        vm.warp(block.timestamp + 2 days);

        IPredictionMarket.OrderFill memory fill = IPredictionMarket.OrderFill({
            orderId: orderId,
            limitPrice: 500_000,
            quantity: 10_000_000,
            recipient: address(0)
        });

        vm.prank(TRADER_B);
        vm.expectRevert();
        market.fillOrder(fill);
    }

    /// @notice YES and NO stake calculations are correct.
    function testStakeCalculationAccuracy() public {
        IPredictionMarket.OrderSubmission memory yesOrder = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 700_000,
            quantity: 100_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        uint256 balanceABefore = collateral.balanceOf(TRADER_A);

        vm.prank(TRADER_A);
        market.submitOrder(yesOrder);

        uint256 expectedYesStake = (uint256(700_000) * 100_000_000) / 1_000_000;
        assertEq(collateral.balanceOf(TRADER_A), balanceABefore - expectedYesStake, "YES stake correct");

        IPredictionMarket.OrderSubmission memory noOrder = IPredictionMarket.OrderSubmission({
            marketId: marketId,
            position: IPredictionMarket.Outcome.No,
            price: 300_000,
            quantity: 100_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        uint256 balanceBBefore = collateral.balanceOf(TRADER_B);

        vm.prank(TRADER_B);
        market.submitOrder(noOrder);

        uint256 expectedNoStake = (uint256(1_000_000 - 300_000) * 100_000_000) / 1_000_000;
        assertEq(collateral.balanceOf(TRADER_B), balanceBBefore - expectedNoStake, "NO stake correct");
    }

    /// @notice Fee siphoning matches configured basis points after resolution.
    function testFeeCalculationAccuracy() public {
        uint64 closeEpoch = uint64(block.timestamp + 1 days);

        IPredictionMarket.MarketCreation memory params = IPredictionMarket.MarketCreation({
            questionURI: "ipfs://fee-test",
            oracleURI: "https://example.com/oracle",
            openEpoch: uint64(block.timestamp),
            closeEpoch: closeEpoch,
            feeBps: 500
        });

        vm.prank(CREATION_AGENT);
        IPredictionMarket.MarketId testMarketId = market.createMarket(params);

        IPredictionMarket.OrderSubmission memory submission = IPredictionMarket.OrderSubmission({
            marketId: testMarketId,
            position: IPredictionMarket.Outcome.Yes,
            price: 500_000,
            quantity: 100_000_000,
            orderType: IPredictionMarket.OrderType.GoodTilCancel,
            expirationEpoch: 0,
            recipient: address(0)
        });

        vm.prank(TRADER_A);
        IPredictionMarket.OrderId orderId = market.submitOrder(submission);

        IPredictionMarket.OrderFill memory fill = IPredictionMarket.OrderFill({
            orderId: orderId,
            limitPrice: 500_000,
            quantity: 100_000_000,
            recipient: address(0)
        });

        vm.prank(TRADER_B);
        market.fillOrder(fill);

        uint64 resolvedTimestamp = closeEpoch + 1;
        vm.warp(resolvedTimestamp);

        IPredictionMarket.Resolution memory resolution = IPredictionMarket.Resolution({
            outcome: IPredictionMarket.Outcome.Yes,
            resolutionURI: "ipfs://resolution",
            evidenceURI: "ipfs://evidence",
            resolvedAt: resolvedTimestamp
        });

        vm.prank(RESOLUTION_AGENT);
        market.resolveMarket(testMarketId, resolution);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        market.finalizeMarket(testMarketId);

        uint256 feeRecipientBefore = collateral.balanceOf(FEE_RECIPIENT);

        vm.prank(TRADER_A);
        uint256 payout = market.claimPayout(testMarketId, IPredictionMarket.Outcome.Yes, address(0));

        uint256 expectedFee = (submission.quantity * 500) / 10_000;
        uint256 expectedPayout = submission.quantity - expectedFee;

        assertEq(payout, expectedPayout, "payout after 5% fee");
        assertEq(collateral.balanceOf(FEE_RECIPIENT), feeRecipientBefore + expectedFee, "fee recipient credited");
    }

    function _createDefaultMarket(uint16 feeBps) private returns (IPredictionMarket.MarketId) {
        IPredictionMarket.MarketCreation memory params = IPredictionMarket.MarketCreation({
            questionURI: "ipfs://QmTest",
            oracleURI: "https://example.com/oracle",
            openEpoch: uint64(block.timestamp),
            closeEpoch: uint64(block.timestamp + 1 days),
            feeBps: feeBps
        });

        vm.prank(CREATION_AGENT);
        return market.createMarket(params);
    }

    function _warpToClose() private {
        vm.warp(block.timestamp + 1 days + 1);
    }
}
