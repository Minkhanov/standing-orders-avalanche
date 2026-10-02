// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StandingOrders, IUSDC} from "../src/StandingOrders.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract StandingOrdersTest is Test {
    StandingOrders internal so;
    MockUSDC internal usdc;

    address internal merchant = makeAddr("merchant");
    uint256 internal subscriberKey = 0xA11CE;
    address internal subscriber;
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    uint96 internal constant PRICE = 9_990_000; // 9.99 USDC (6 decimals)
    uint32 internal constant MONTH = 30 days;

    event PlanCreated(uint256 indexed planId, address indexed merchant, uint256 price, uint32 period, string name);
    event Subscribed(uint256 indexed subscriptionId, uint256 indexed planId, address indexed subscriber);
    event Charged(
        uint256 indexed subscriptionId,
        uint256 indexed planId,
        address indexed subscriber,
        address merchant,
        uint256 amount,
        uint32 chargeNumber,
        uint64 nextChargeAt
    );
    event ChargeFailed(uint256 indexed subscriptionId, bytes reason);
    event Cancelled(uint256 indexed subscriptionId, address indexed by);

    function setUp() public {
        vm.warp(1_790_000_000);
        usdc = new MockUSDC();
        so = new StandingOrders(IUSDC(address(usdc)));
        subscriber = vm.addr(subscriberKey);
        usdc.mint(subscriber, 1_000e6);
        usdc.mint(stranger, 1_000e6);
    }

    // ------------------------------------------------------------ helpers

    function _plan() internal returns (uint256) {
        vm.prank(merchant);
        return so.createPlan("Pro", PRICE, MONTH);
    }

    function _approveAndSubscribe(address who, uint256 planId, uint256 periods) internal returns (uint256) {
        vm.startPrank(who);
        usdc.approve(address(so), uint256(PRICE) * periods);
        uint256 id = so.subscribe(planId, 0);
        vm.stopPrank();
        return id;
    }

    function _permitSig(uint256 key, address owner, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash =
            keccak256(abi.encode(usdc.PERMIT_TYPEHASH(), owner, address(so), value, usdc.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(key, digest);
    }

    // ------------------------------------------------------------ constructor & plans

    function test_RevertWhen_TokenHasNoCode() public {
        vm.expectRevert(StandingOrders.InvalidToken.selector);
        new StandingOrders(IUSDC(address(0x1234)));
    }

    function test_CreatePlan() public {
        vm.expectEmit(true, true, false, true, address(so));
        emit PlanCreated(1, merchant, PRICE, MONTH, "Pro");
        uint256 id = _plan();
        assertEq(id, 1);
        StandingOrders.Plan memory p = so.plan(id);
        assertEq(p.merchant, merchant);
        assertEq(p.price, PRICE);
        assertEq(p.period, MONTH);
        assertTrue(p.active);
        assertEq(p.name, "Pro");
        assertEq(so.plansOf(merchant).length, 1);
        assertEq(so.planCount(), 1);
    }

    function test_RevertWhen_PlanParamsInvalid() public {
        vm.startPrank(merchant);
        vm.expectRevert(StandingOrders.InvalidPrice.selector);
        so.createPlan("x", 0, MONTH);
        vm.expectRevert(StandingOrders.InvalidPeriod.selector);
        so.createPlan("x", PRICE, 59);
        vm.expectRevert(StandingOrders.InvalidPeriod.selector);
        so.createPlan("x", PRICE, 367 days);
        vm.expectRevert(StandingOrders.InvalidName.selector);
        so.createPlan("", PRICE, MONTH);
        vm.expectRevert(StandingOrders.InvalidName.selector);
        so.createPlan(string(new bytes(65)), PRICE, MONTH);
        vm.stopPrank();
    }

    function test_OnlyMerchantCanPausePlan() public {
        uint256 planId = _plan();
        vm.prank(stranger);
        vm.expectRevert(StandingOrders.NotMerchant.selector);
        so.setPlanActive(planId, false);

        vm.prank(merchant);
        so.setPlanActive(planId, false);
        assertFalse(so.plan(planId).active);
    }

    // ------------------------------------------------------------ subscribe

    function test_SubscribeChargesFirstPeriodImmediately() public {
        uint256 planId = _plan();
        vm.prank(subscriber);
        usdc.approve(address(so), uint256(PRICE) * 12);

        vm.expectEmit(true, true, true, true, address(so));
        emit Subscribed(1, planId, subscriber);
        vm.expectEmit(true, true, true, true, address(so));
        emit Charged(1, planId, subscriber, merchant, PRICE, 1, uint64(vm.getBlockTimestamp()) + MONTH);
        vm.prank(subscriber);
        uint256 subId = so.subscribe(planId, 12);

        assertEq(usdc.balanceOf(merchant), PRICE);
        assertEq(usdc.balanceOf(subscriber), 1_000e6 - PRICE);
        assertEq(usdc.balanceOf(address(so)), 0, "contract holds no USDC");

        StandingOrders.Subscription memory s = so.subscription(subId);
        assertEq(s.subscriber, subscriber);
        assertEq(s.planId, planId);
        assertEq(s.chargeCount, 1);
        assertEq(s.nextChargeAt, vm.getBlockTimestamp() + MONTH);
        assertTrue(s.active);
        assertEq(so.activeSubscriptionOf(subscriber, planId), subId);
        assertFalse(so.isDue(subId));
    }

    function test_RevertWhen_SubscribeWithoutAllowance_BubblesTokenReason() public {
        uint256 planId = _plan();
        vm.prank(subscriber);
        vm.expectRevert(bytes("ERC20: transfer amount exceeds allowance"));
        so.subscribe(planId, 0);
    }

    function test_RevertWhen_SubscribeTwice() public {
        uint256 planId = _plan();
        uint256 subId = _approveAndSubscribe(subscriber, planId, 12);
        vm.prank(subscriber);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.AlreadySubscribed.selector, subId));
        so.subscribe(planId, 0);
    }

    function test_RevertWhen_PlanUnknownOrPaused() public {
        vm.prank(subscriber);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.UnknownPlan.selector, 7));
        so.subscribe(7, 0);

        uint256 planId = _plan();
        vm.prank(merchant);
        so.setPlanActive(planId, false);
        vm.prank(subscriber);
        usdc.approve(address(so), PRICE);
        vm.prank(subscriber);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.PlanInactive.selector, planId));
        so.subscribe(planId, 0);
    }

    function test_SubscribeWithPermitInOneTransaction() public {
        uint256 planId = _plan();
        uint256 cap = uint256(PRICE) * 12;
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(subscriberKey, subscriber, cap, deadline);

        vm.prank(subscriber);
        uint256 subId = so.subscribeWithPermit(planId, 12, cap, deadline, v, r, s);

        assertEq(usdc.balanceOf(merchant), PRICE);
        assertEq(usdc.allowance(subscriber, address(so)), cap - PRICE);
        assertEq(so.subscription(subId).maxCharges, 12);
        assertTrue(so.subscription(subId).active);
    }

    function test_PermitFrontRunCannotBlockSubscription() public {
        uint256 planId = _plan();
        uint256 cap = uint256(PRICE) * 3;
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(subscriberKey, subscriber, cap, deadline);

        // An observer submits the same permit first.
        vm.prank(stranger);
        usdc.permit(subscriber, address(so), cap, deadline, v, r, s);

        vm.prank(subscriber);
        uint256 subId = so.subscribeWithPermit(planId, 3, cap, deadline, v, r, s);
        assertTrue(so.subscription(subId).active);
        assertEq(usdc.balanceOf(merchant), PRICE);
    }

    // ------------------------------------------------------------ charge

    function test_RevertWhen_ChargedEarly() public {
        uint256 planId = _plan();
        uint256 subId = _approveAndSubscribe(subscriber, planId, 12);
        uint64 next = so.subscription(subId).nextChargeAt;
        vm.warp(next - 1);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.NotDue.selector, next));
        so.charge(subId);
    }

    function test_ChargeOnScheduleByAnyone_FundsGoToMerchant() public {
        uint256 planId = _plan();
        uint256 subId = _approveAndSubscribe(subscriber, planId, 12);
        uint64 next = so.subscription(subId).nextChargeAt;

        vm.warp(next);
        assertTrue(so.isDue(subId));
        vm.prank(keeper);
        so.charge(subId);

        assertEq(usdc.balanceOf(merchant), uint256(PRICE) * 2);
        assertEq(usdc.balanceOf(keeper), 0, "caller gets nothing");
        StandingOrders.Subscription memory s = so.subscription(subId);
        assertEq(s.chargeCount, 2);
        assertEq(s.nextChargeAt, next + MONTH, "schedule does not drift");

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.NotDue.selector, next + MONTH));
        so.charge(subId);
    }

    function test_MissedPeriodsAreNotBackCharged() public {
        uint256 planId = _plan();
        uint256 subId = _approveAndSubscribe(subscriber, planId, 12);
        uint64 next = so.subscription(subId).nextChargeAt;

        vm.warp(next + 3 * MONTH + 5 days); // three and a half periods late
        so.charge(subId);
        assertEq(usdc.balanceOf(merchant), uint256(PRICE) * 2, "only one period charged");
        assertEq(so.subscription(subId).nextChargeAt, vm.getBlockTimestamp() + MONTH);

        vm.expectRevert();
        so.charge(subId);
    }

    function test_AllowanceIsAHardCap() public {
        uint256 planId = _plan();
        uint256 subId = _approveAndSubscribe(subscriber, planId, 3); // 3 periods pre-approved

        vm.warp(vm.getBlockTimestamp() + MONTH);
        so.charge(subId);
        vm.warp(vm.getBlockTimestamp() + MONTH);
        so.charge(subId);
        assertEq(usdc.balanceOf(merchant), uint256(PRICE) * 3);

        vm.warp(vm.getBlockTimestamp() + MONTH);
        vm.expectRevert(bytes("ERC20: transfer amount exceeds allowance"));
        so.charge(subId);
        assertEq(usdc.balanceOf(merchant), uint256(PRICE) * 3, "no 4th charge without new approval");
    }

    function test_RevertWhen_ChargeCancelledOrPaused() public {
        uint256 planId = _plan();
        uint256 subA = _approveAndSubscribe(subscriber, planId, 12);
        uint256 subB = _approveAndSubscribe(stranger, planId, 12);
        vm.warp(vm.getBlockTimestamp() + MONTH);

        vm.prank(subscriber);
        so.cancel(subA);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.SubscriptionInactive.selector, subA));
        so.charge(subA);

        vm.prank(merchant);
        so.setPlanActive(planId, false);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.PlanInactive.selector, planId));
        so.charge(subB);
        assertFalse(so.isDue(subB));

        vm.prank(merchant);
        so.setPlanActive(planId, true);
        so.charge(subB);
        assertEq(so.subscription(subB).chargeCount, 2);
    }

    function test_RevertWhen_UnknownSubscription() public {
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.UnknownSubscription.selector, 42));
        so.charge(42);
    }

    // ------------------------------------------------------------ cancel

    function test_CancelBySubscriberOrMerchantOnly() public {
        uint256 planId = _plan();
        uint256 subId = _approveAndSubscribe(subscriber, planId, 12);

        vm.prank(stranger);
        vm.expectRevert(StandingOrders.NotAuthorized.selector);
        so.cancel(subId);

        vm.expectEmit(true, true, false, false, address(so));
        emit Cancelled(subId, merchant);
        vm.prank(merchant);
        so.cancel(subId);
        assertFalse(so.subscription(subId).active);
        assertEq(so.activeSubscriptionOf(subscriber, planId), 0);

        vm.prank(subscriber);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.SubscriptionInactive.selector, subId));
        so.cancel(subId);
    }

    function test_CanResubscribeAfterCancel() public {
        uint256 planId = _plan();
        uint256 first = _approveAndSubscribe(subscriber, planId, 12);
        vm.prank(subscriber);
        so.cancel(first);
        uint256 second = _approveAndSubscribe(subscriber, planId, 12);
        assertTrue(second != first);
        assertEq(so.activeSubscriptionOf(subscriber, planId), second);
        assertEq(so.subscriptionsOf(subscriber).length, 2);
    }

    function test_MaxChargesIsAPerSubscriptionCap() public {
        uint256 planId = _plan();
        vm.startPrank(subscriber);
        usdc.approve(address(so), type(uint256).max); // even an unlimited allowance...
        uint256 subId = so.subscribe(planId, 2); // ...cannot exceed 2 charges
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + MONTH);
        so.charge(subId);
        assertEq(so.subscription(subId).chargeCount, 2);

        vm.warp(vm.getBlockTimestamp() + MONTH);
        assertFalse(so.isDue(subId), "capped subscription is never due");
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.CapReached.selector, subId));
        so.charge(subId);
        assertEq(usdc.balanceOf(merchant), uint256(PRICE) * 2);
    }

    function test_SharedAllowanceDoesNotLetOnePlanDrainAnother() public {
        uint256 planA = _plan();
        vm.prank(merchant);
        uint256 planB = so.createPlan("Basic", 1e6, MONTH);

        vm.startPrank(subscriber);
        usdc.approve(address(so), uint256(PRICE) * 2 + 1e6 * 2);
        uint256 subA = so.subscribe(planA, 2);
        uint256 subB = so.subscribe(planB, 2);
        vm.stopPrank();

        for (uint256 i = 0; i < 3; i++) {
            vm.warp(vm.getBlockTimestamp() + MONTH);
            uint256[] memory ids = new uint256[](2);
            ids[0] = subA;
            ids[1] = subB;
            so.chargeDue(ids);
        }
        assertEq(so.subscription(subA).chargeCount, 2);
        assertEq(so.subscription(subB).chargeCount, 2);
        assertEq(usdc.allowance(subscriber, address(so)), 0);
    }

    // ------------------------------------------------------------ batch charging

    function test_ChargeDueSkipsNotDueAndReportsFailures() public {
        uint256 planId = _plan();
        uint256 ok1 = _approveAndSubscribe(subscriber, planId, 12);
        uint256 broke = _approveAndSubscribe(stranger, planId, 1); // allowance only for the first period

        address late = makeAddr("late");
        usdc.mint(late, 100e6);
        vm.warp(vm.getBlockTimestamp() + MONTH);
        uint256 notDue = _approveAndSubscribe(late, planId, 12); // subscribed now, due next month

        uint256[] memory ids = new uint256[](4);
        ids[0] = ok1;
        ids[1] = broke;
        ids[2] = notDue;
        ids[3] = 999; // unknown id: ignored

        uint256[] memory due = so.dueSubscriptionsOfPlan(planId, 0, 10);
        assertEq(due.length, 2);
        assertEq(due[0], ok1);
        assertEq(due[1], broke);

        uint64 brokeNextBefore = so.subscription(broke).nextChargeAt;
        vm.expectEmit(true, false, false, true, address(so));
        emit ChargeFailed(broke, abi.encodeWithSignature("Error(string)", "ERC20: transfer amount exceeds allowance"));
        vm.prank(keeper);
        uint256 charged = so.chargeDue(ids);

        assertEq(charged, 1);
        assertEq(so.subscription(ok1).chargeCount, 2);
        assertEq(so.subscription(broke).chargeCount, 1, "failed charge left no trace");
        assertEq(so.subscription(broke).nextChargeAt, brokeNextBefore);
        assertTrue(so.isDue(broke), "still due, merchant decides what to do");
        assertEq(so.subscription(notDue).chargeCount, 1);
    }

    function test_Pagination() public {
        uint256 planId = _plan();
        for (uint256 i = 0; i < 5; i++) {
            address who = address(uint160(0x1000 + i));
            usdc.mint(who, 100e6);
            _approveAndSubscribe(who, planId, 2);
        }
        assertEq(so.subscriptionCountOfPlan(planId), 5);
        uint256[] memory page = so.subscriptionsOfPlan(planId, 3, 10);
        assertEq(page.length, 2);
        assertEq(page[0], 4);
        assertEq(page[1], 5);
        assertEq(so.subscriptionsOfPlan(planId, 5, 10).length, 0);
    }

    // ------------------------------------------------------------ fuzz

    /// Any sequence of waits yields at most one charge per call and never before it is due.
    function testFuzz_ScheduleNeverChargesEarly(uint32 period, uint32[5] memory waits) public {
        period = uint32(bound(period, so.MIN_PERIOD(), so.MAX_PERIOD()));
        vm.prank(merchant);
        uint256 planId = so.createPlan("Fuzz", 1e6, period);
        usdc.mint(subscriber, 10_000e6);
        uint256 subId = _approveAndSubscribe(subscriber, planId, 10_000);

        uint256 expectedCharges = 1;
        for (uint256 i = 0; i < waits.length; i++) {
            vm.warp(vm.getBlockTimestamp() + bound(waits[i], 0, uint256(period) * 3));
            uint64 next = so.subscription(subId).nextChargeAt;
            if (vm.getBlockTimestamp() >= next) {
                so.charge(subId);
                expectedCharges++;
                assertGt(so.subscription(subId).nextChargeAt, vm.getBlockTimestamp());
            } else {
                vm.expectRevert(abi.encodeWithSelector(StandingOrders.NotDue.selector, next));
                so.charge(subId);
            }
        }
        assertEq(so.subscription(subId).chargeCount, expectedCharges);
        assertEq(usdc.balanceOf(merchant), expectedCharges * 1e6);
        assertEq(usdc.balanceOf(address(so)), 0);
    }
}
