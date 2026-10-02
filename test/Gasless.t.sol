// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StandingOrders, IUSDC} from "../src/StandingOrders.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Tests for the gasless (relayed) flow added for Avalanche: `subscribeFor`,
///         `subscribeWithPermitFor` and `cancelFor`. The subscriber signs; the merchant or any other
///         relayer submits and pays the AVAX gas. The subscriber holds USDC only.
contract GaslessTest is Test {
    StandingOrders internal so;
    MockUSDC internal usdc;

    address internal merchant = makeAddr("merchant");
    address internal relayer = makeAddr("relayer");
    address internal keeper = makeAddr("keeper");
    uint256 internal subKey = 0xA11CE;
    address internal sub;

    uint96 internal constant PRICE = 9_990_000; // 9.99 USDC
    uint32 internal constant MONTH = 30 days;
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

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
    event Cancelled(uint256 indexed subscriptionId, address indexed by);

    function setUp() public {
        vm.warp(1_790_000_000);
        usdc = new MockUSDC();
        so = new StandingOrders(IUSDC(address(usdc)));
        sub = vm.addr(subKey);
        usdc.mint(sub, 1_000e6);
        // The whole point: the subscriber owns no AVAX and nobody ever sends any.
        vm.deal(sub, 0);
        vm.deal(relayer, 10 ether);
    }

    // ------------------------------------------------------------ helpers

    function _plan() internal returns (uint256) {
        vm.prank(merchant);
        return so.createPlan("Pro", PRICE, MONTH);
    }

    function _domainSeparator(address verifying, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("StandingOrders"),
                keccak256("1"),
                chainId,
                verifying
            )
        );
    }

    function _digest(bytes32 structHash, address verifying, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(verifying, chainId), structHash));
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _subscribeHash(address who, uint256 planId, uint32 maxCharges, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(so.SUBSCRIBE_TYPEHASH(), who, planId, maxCharges, nonce, deadline));
    }

    function _cancelHash(address who, uint256 subscriptionId, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(so.CANCEL_TYPEHASH(), who, subscriptionId, nonce, deadline));
    }

    function _subscribeSig(uint256 key, uint256 planId, uint32 maxCharges, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 h = _subscribeHash(vm.addr(key), planId, maxCharges, nonce, deadline);
        return _sign(key, _digest(h, address(so), block.chainid));
    }

    function _cancelSig(uint256 key, uint256 subscriptionId, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 h = _cancelHash(vm.addr(key), subscriptionId, nonce, deadline);
        return _sign(key, _digest(h, address(so), block.chainid));
    }

    function _permit(uint256 key, uint256 value, uint256 deadline)
        internal
        view
        returns (StandingOrders.Permit memory p)
    {
        address owner = vm.addr(key);
        bytes32 structHash =
            keccak256(abi.encode(usdc.PERMIT_TYPEHASH(), owner, address(so), value, usdc.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        p = StandingOrders.Permit({value: value, deadline: deadline, v: v, r: r, s: s});
    }

    function _deadline() internal view returns (uint256) {
        return vm.getBlockTimestamp() + 30 minutes;
    }

    /// Full gasless subscribe by `relayer`: returns the subscription id.
    function _relayedSubscribe(uint256 planId, uint32 maxCharges) internal returns (uint256 subId) {
        uint256 deadline = _deadline();
        bytes memory sig = _subscribeSig(subKey, planId, maxCharges, so.nonces(sub), deadline);
        StandingOrders.Permit memory permit = _permit(subKey, uint256(PRICE) * 12, deadline);
        vm.prank(relayer);
        subId = so.subscribeWithPermitFor(sub, planId, maxCharges, deadline, sig, permit);
    }

    // ------------------------------------------------------------ domain

    function test_DomainSeparatorMatchesEip712Spec() public view {
        assertEq(so.DOMAIN_SEPARATOR(), _domainSeparator(address(so), block.chainid));
        assertEq(so.NAME(), "StandingOrders");
        assertEq(so.VERSION(), "1");
    }

    function test_DomainSeparatorFollowsChainId() public {
        vm.chainId(43_113);
        assertEq(so.DOMAIN_SEPARATOR(), _domainSeparator(address(so), 43_113));
        vm.chainId(43_114);
        assertEq(so.DOMAIN_SEPARATOR(), _domainSeparator(address(so), 43_114));
    }

    // ------------------------------------------------------------ gasless subscribe

    function test_SubscribeWithPermitFor_RelayerPaysGas_SubscriberHoldsOnlyUsdc() public {
        uint256 planId = _plan();
        uint256 deadline = _deadline();
        uint256 cap = uint256(PRICE) * 12;
        bytes memory sig = _subscribeSig(subKey, planId, 12, 0, deadline);
        StandingOrders.Permit memory permit = _permit(subKey, cap, deadline);

        vm.expectEmit(true, true, true, true, address(so));
        emit Subscribed(1, planId, sub);
        vm.expectEmit(true, true, true, true, address(so));
        emit Charged(1, planId, sub, merchant, PRICE, 1, uint64(vm.getBlockTimestamp()) + MONTH);
        vm.prank(relayer);
        uint256 subId = so.subscribeWithPermitFor(sub, planId, 12, deadline, sig, permit);

        // The subscription belongs to the signer, not to the relayer.
        StandingOrders.Subscription memory s = so.subscription(subId);
        assertEq(s.subscriber, sub);
        assertEq(s.maxCharges, 12);
        assertEq(s.chargeCount, 1);
        assertTrue(s.active);
        assertEq(so.activeSubscriptionOf(sub, planId), subId);
        assertEq(so.activeSubscriptionOf(relayer, planId), 0);

        // Money moved subscriber -> merchant; nothing touched the relayer's USDC, no AVAX anywhere near the subscriber.
        assertEq(usdc.balanceOf(merchant), PRICE);
        assertEq(usdc.balanceOf(sub), 1_000e6 - PRICE);
        assertEq(usdc.balanceOf(relayer), 0);
        assertEq(usdc.balanceOf(address(so)), 0, "contract holds no USDC");
        assertEq(usdc.allowance(sub, address(so)), cap - PRICE);
        assertEq(sub.balance, 0, "subscriber never needed AVAX");
        assertEq(address(so).balance, 0);
        assertEq(so.nonces(sub), 1, "nonce consumed");
    }

    function test_SubscribeFor_UsesExistingAllowance() public {
        uint256 planId = _plan();
        vm.prank(sub);
        usdc.approve(address(so), type(uint256).max);

        uint256 deadline = _deadline();
        bytes memory sig = _subscribeSig(subKey, planId, 0, 0, deadline);
        vm.prank(relayer);
        uint256 subId = so.subscribeFor(sub, planId, 0, deadline, sig);

        assertEq(so.subscription(subId).subscriber, sub);
        assertEq(usdc.balanceOf(merchant), PRICE);
    }

    function test_RevertWhen_SubscribeForWithoutAllowance_BubblesTokenReason() public {
        uint256 planId = _plan();
        uint256 deadline = _deadline();
        bytes memory sig = _subscribeSig(subKey, planId, 0, 0, deadline);
        vm.prank(relayer);
        vm.expectRevert(bytes("ERC20: transfer amount exceeds allowance"));
        so.subscribeFor(sub, planId, 0, deadline, sig);
        assertEq(so.nonces(sub), 0, "failed call leaves the nonce untouched");
    }

    function test_RelayedSubscribeMatchesSelfPaidState() public {
        uint256 planId = _plan();
        // Self-paid reference.
        address other = makeAddr("other");
        usdc.mint(other, 1_000e6);
        vm.startPrank(other);
        usdc.approve(address(so), uint256(PRICE) * 12);
        uint256 selfId = so.subscribe(planId, 12);
        vm.stopPrank();

        uint256 relayedId = _relayedSubscribe(planId, 12);

        StandingOrders.Subscription memory a = so.subscription(selfId);
        StandingOrders.Subscription memory b = so.subscription(relayedId);
        assertEq(a.planId, b.planId);
        assertEq(a.chargeCount, b.chargeCount);
        assertEq(a.nextChargeAt, b.nextChargeAt);
        assertEq(a.startedAt, b.startedAt);
        assertEq(a.maxCharges, b.maxCharges);
        assertEq(a.active, b.active);
        assertEq(so.subscriptionsOf(sub).length, 1);
        assertEq(so.subscriptionCountOfPlan(planId), 2);
    }

    function test_RevertWhen_AlreadySubscribedViaRelayer() public {
        uint256 planId = _plan();
        uint256 first = _relayedSubscribe(planId, 12);
        uint256 deadline = _deadline();
        bytes memory sig = _subscribeSig(subKey, planId, 12, so.nonces(sub), deadline);
        StandingOrders.Permit memory permit = _permit(subKey, uint256(PRICE) * 12, deadline);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.AlreadySubscribed.selector, first));
        so.subscribeWithPermitFor(sub, planId, 12, deadline, sig, permit);
    }

    function test_RevertWhen_PlanUnknownOrPausedViaRelayer() public {
        uint256 deadline = _deadline();
        bytes memory sig = _subscribeSig(subKey, 7, 0, 0, deadline);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.UnknownPlan.selector, 7));
        so.subscribeFor(sub, 7, 0, deadline, sig);

        uint256 planId = _plan();
        vm.prank(merchant);
        so.setPlanActive(planId, false);
        sig = _subscribeSig(subKey, planId, 0, 0, deadline);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.PlanInactive.selector, planId));
        so.subscribeFor(sub, planId, 0, deadline, sig);
    }

    // ------------------------------------------------------------ permit edge cases

    function test_PermitFrontRunDoesNotBlockRelayedSubscribe() public {
        uint256 planId = _plan();
        uint256 deadline = _deadline();
        bytes memory sig = _subscribeSig(subKey, planId, 3, 0, deadline);
        StandingOrders.Permit memory permit = _permit(subKey, uint256(PRICE) * 3, deadline);

        // An observer submits the permit first; the relayed call must still succeed.
        address observer = makeAddr("observer");
        vm.prank(observer);
        usdc.permit(sub, address(so), permit.value, permit.deadline, permit.v, permit.r, permit.s);

        vm.prank(relayer);
        uint256 subId = so.subscribeWithPermitFor(sub, planId, 3, deadline, sig, permit);
        assertTrue(so.subscription(subId).active);
        assertEq(usdc.balanceOf(merchant), PRICE);
    }

    function test_RevertWhen_PermitInvalidAndNoAllowance() public {
        uint256 planId = _plan();
        uint256 deadline = _deadline();
        bytes memory sig = _subscribeSig(subKey, planId, 3, 0, deadline);
        // A permit signed by somebody else is ignored (try/catch), so the pull has no allowance.
        StandingOrders.Permit memory bad = _permit(0xB0B, uint256(PRICE) * 3, deadline);
        vm.prank(relayer);
        vm.expectRevert(bytes("ERC20: transfer amount exceeds allowance"));
        so.subscribeWithPermitFor(sub, planId, 3, deadline, sig, bad);
    }

    function test_RevertWhen_PermitTooSmallForFirstPeriod() public {
        uint256 planId = _plan();
        uint256 deadline = _deadline();
        bytes memory sig = _subscribeSig(subKey, planId, 3, 0, deadline);
        StandingOrders.Permit memory small = _permit(subKey, uint256(PRICE) - 1, deadline);
        vm.prank(relayer);
        vm.expectRevert(bytes("ERC20: transfer amount exceeds allowance"));
        so.subscribeWithPermitFor(sub, planId, 3, deadline, sig, small);
    }

    // ------------------------------------------------------------ signature rejection

    function test_RevertWhen_SignatureExpired() public {
        uint256 planId = _plan();
        uint256 deadline = _deadline();
        bytes memory sig = _subscribeSig(subKey, planId, 0, 0, deadline);
        vm.prank(sub);
        usdc.approve(address(so), type(uint256).max);

        vm.warp(deadline + 1);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.SignatureExpired.selector, deadline));
        so.subscribeFor(sub, planId, 0, deadline, sig);

        // Exactly at the deadline it is still valid.
        vm.warp(deadline);
        vm.prank(relayer);
        so.subscribeFor(sub, planId, 0, deadline, sig);
    }

    function test_RevertWhen_SignedByWrongKey() public {
        uint256 planId = _plan();
        vm.prank(sub);
        usdc.approve(address(so), type(uint256).max);
        uint256 deadline = _deadline();
        bytes memory sig = _subscribeSig(0xBAD, planId, 0, 0, deadline); // signed by someone else
        vm.prank(relayer);
        vm.expectRevert(StandingOrders.InvalidSigner.selector);
        so.subscribeFor(sub, planId, 0, deadline, sig);
    }

    function test_RevertWhen_RelayerAltersAnySignedField() public {
        uint256 planId = _plan();
        vm.prank(merchant);
        uint256 otherPlan = so.createPlan("Elite", 99e6, MONTH);
        vm.startPrank(sub);
        usdc.approve(address(so), type(uint256).max);
        vm.stopPrank();
        address victim = makeAddr("victim");
        usdc.mint(victim, 1_000e6);
        vm.prank(victim);
        usdc.approve(address(so), type(uint256).max);

        uint256 deadline = _deadline();
        bytes memory sig = _subscribeSig(subKey, planId, 12, 0, deadline);

        vm.startPrank(relayer);
        // different plan (e.g. a pricier one)
        vm.expectRevert(StandingOrders.InvalidSigner.selector);
        so.subscribeFor(sub, otherPlan, 12, deadline, sig);
        // different cap
        vm.expectRevert(StandingOrders.InvalidSigner.selector);
        so.subscribeFor(sub, planId, 0, deadline, sig);
        // different deadline
        vm.expectRevert(StandingOrders.InvalidSigner.selector);
        so.subscribeFor(sub, planId, 12, deadline + 1, sig);
        // different subscriber (try to bill a victim who approved the contract)
        vm.expectRevert(StandingOrders.InvalidSigner.selector);
        so.subscribeFor(victim, planId, 12, deadline, sig);
        vm.stopPrank();

        assertEq(usdc.balanceOf(merchant), 0, "nothing was charged");
        assertEq(so.subscriptionCount(), 0);
        assertEq(so.nonces(sub), 0);
        assertEq(so.nonces(victim), 0);
    }

    function test_RevertWhen_SignatureReplayed() public {
        uint256 planId = _plan();
        uint256 subId = _relayedSubscribe(planId, 12);
        // Capture the signature the relayer used (nonce 0) and cancel, then try to replay it.
        uint256 deadline = vm.getBlockTimestamp() + 20 minutes;
        bytes memory replay = _subscribeSig(subKey, planId, 12, 0, deadline);

        bytes memory cancelSig = _cancelSig(subKey, subId, 1, deadline);
        vm.prank(relayer);
        so.cancelFor(sub, subId, deadline, cancelSig);

        vm.prank(relayer);
        vm.expectRevert(StandingOrders.InvalidSigner.selector);
        so.subscribeFor(sub, planId, 12, deadline, replay); // nonce 0 already used
    }

    function test_RevertWhen_SignatureIsForAnotherDeploymentOrChain() public {
        uint256 planId = _plan();
        vm.prank(sub);
        usdc.approve(address(so), type(uint256).max);
        uint256 deadline = _deadline();

        // Signed for another StandingOrders instance.
        StandingOrders twin = new StandingOrders(IUSDC(address(usdc)));
        bytes32 h = _subscribeHash(sub, planId, 0, 0, deadline);
        bytes memory forTwin = _sign(subKey, _digest(h, address(twin), block.chainid));
        vm.prank(relayer);
        vm.expectRevert(StandingOrders.InvalidSigner.selector);
        so.subscribeFor(sub, planId, 0, deadline, forTwin);

        // Signed for another chain id (cross-chain replay).
        bytes memory otherChain = _sign(subKey, _digest(h, address(so), 1));
        vm.prank(relayer);
        vm.expectRevert(StandingOrders.InvalidSigner.selector);
        so.subscribeFor(sub, planId, 0, deadline, otherChain);

        // The correct one works.
        bytes memory good = _sign(subKey, _digest(h, address(so), block.chainid));
        vm.prank(relayer);
        so.subscribeFor(sub, planId, 0, deadline, good);
    }

    function test_RevertWhen_SignatureMalformedOrMalleable() public {
        uint256 planId = _plan();
        vm.prank(sub);
        usdc.approve(address(so), type(uint256).max);
        uint256 deadline = _deadline();
        bytes32 digest = _digest(_subscribeHash(sub, planId, 0, 0, deadline), address(so), block.chainid);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(subKey, digest);

        vm.startPrank(relayer);
        // high-s twin of a valid signature
        bytes32 highS = bytes32(SECP256K1_N - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        vm.expectRevert(StandingOrders.InvalidSignature.selector);
        so.subscribeFor(sub, planId, 0, deadline, abi.encodePacked(r, highS, flippedV));
        // v in {0, 1} (not accepted)
        vm.expectRevert(StandingOrders.InvalidSignature.selector);
        so.subscribeFor(sub, planId, 0, deadline, abi.encodePacked(r, s, v - 27));
        // wrong length
        vm.expectRevert(StandingOrders.InvalidSignature.selector);
        so.subscribeFor(sub, planId, 0, deadline, abi.encodePacked(r, s));
        vm.expectRevert(StandingOrders.InvalidSignature.selector);
        so.subscribeFor(sub, planId, 0, deadline, hex"");
        // ecrecover returns address(0) (r = 0)
        vm.expectRevert(StandingOrders.InvalidSignature.selector);
        so.subscribeFor(sub, planId, 0, deadline, abi.encodePacked(bytes32(0), s, v));
        // zero subscriber can never be a signer
        vm.expectRevert(StandingOrders.InvalidSigner.selector);
        so.subscribeFor(address(0), planId, 0, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // The untouched signature still works.
        vm.prank(relayer);
        so.subscribeFor(sub, planId, 0, deadline, abi.encodePacked(r, s, v));
    }

    function test_RevertWhen_CancelSignatureUsedAsSubscribeSignature() public {
        uint256 planId = _plan();
        vm.prank(sub);
        usdc.approve(address(so), type(uint256).max);
        uint256 deadline = _deadline();
        // Same numeric fields, different message type: planId = subscriptionId = 1, nonce 0.
        bytes memory cancelSig = _cancelSig(subKey, planId, 0, deadline);
        vm.prank(relayer);
        vm.expectRevert(StandingOrders.InvalidSigner.selector);
        so.subscribeFor(sub, planId, 0, deadline, cancelSig);
    }

    function test_RevertWhen_MerchantForgesSubscriptionForNonSigner() public {
        uint256 planId = _plan();
        usdc.mint(address(0xC0FFEE), 100e6);
        vm.prank(address(0xC0FFEE));
        usdc.approve(address(so), type(uint256).max);
        // The merchant signs the message itself, pretending to be the subscriber.
        uint256 merchantKey = 0xDEAD;
        uint256 deadline = _deadline();
        bytes memory forged = _subscribeSig(merchantKey, planId, 0, 0, deadline);
        vm.prank(vm.addr(merchantKey));
        vm.expectRevert(StandingOrders.InvalidSigner.selector);
        so.subscribeFor(address(0xC0FFEE), planId, 0, deadline, forged);
    }

    // ------------------------------------------------------------ gasless cancel

    function test_CancelFor_StopsFutureChargesWithoutSubscriberGas() public {
        uint256 planId = _plan();
        uint256 subId = _relayedSubscribe(planId, 12);
        vm.warp(vm.getBlockTimestamp() + MONTH);
        so.charge(subId);
        assertEq(usdc.balanceOf(merchant), uint256(PRICE) * 2);

        uint256 deadline = _deadline();
        bytes memory sig = _cancelSig(subKey, subId, so.nonces(sub), deadline);
        vm.expectEmit(true, true, false, false, address(so));
        emit Cancelled(subId, sub);
        vm.prank(relayer);
        so.cancelFor(sub, subId, deadline, sig);

        assertFalse(so.subscription(subId).active);
        assertEq(so.activeSubscriptionOf(sub, planId), 0);
        assertEq(sub.balance, 0);
        assertEq(so.nonces(sub), 2);

        vm.warp(vm.getBlockTimestamp() + MONTH);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.SubscriptionInactive.selector, subId));
        so.charge(subId);
        assertEq(usdc.balanceOf(merchant), uint256(PRICE) * 2, "no charge after cancel");
    }

    function test_RevertWhen_CancelForRejected() public {
        uint256 planId = _plan();
        uint256 subId = _relayedSubscribe(planId, 12);
        uint256 deadline = _deadline();
        uint256 nonce = so.nonces(sub);
        uint256 strangerKey = 0xB0B;

        // Build every signature first: helpers call the contract, which would swallow expectRevert.
        bytes memory unknownSub = _cancelSig(subKey, 99, nonce, deadline);
        bytes memory notOwner = _cancelSig(strangerKey, subId, 0, deadline);
        bytes memory wrongSigner = _cancelSig(strangerKey, subId, nonce, deadline);
        bytes memory badNonce = _cancelSig(subKey, subId, nonce + 1, deadline);
        bytes memory good = _cancelSig(subKey, subId, nonce, deadline);
        address strangerAddr = vm.addr(strangerKey);

        vm.startPrank(relayer);
        // unknown subscription
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.UnknownSubscription.selector, 99));
        so.cancelFor(sub, 99, deadline, unknownSub);
        // signer is not the owner of the subscription
        vm.expectRevert(StandingOrders.InvalidSubscriber.selector);
        so.cancelFor(strangerAddr, subId, deadline, notOwner);
        // wrong signer for the claimed subscriber
        vm.expectRevert(StandingOrders.InvalidSigner.selector);
        so.cancelFor(sub, subId, deadline, wrongSigner);
        // bad nonce
        vm.expectRevert(StandingOrders.InvalidSigner.selector);
        so.cancelFor(sub, subId, deadline, badNonce);
        // expired
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.SignatureExpired.selector, deadline));
        so.cancelFor(sub, subId, deadline, good);
        vm.stopPrank();

        assertTrue(so.subscription(subId).active, "still active after all failed attempts");
    }

    function test_RevertWhen_CancelForReplayedOrAlreadyCancelled() public {
        uint256 planId = _plan();
        uint256 subId = _relayedSubscribe(planId, 12);
        uint256 deadline = _deadline();
        bytes memory sig = _cancelSig(subKey, subId, so.nonces(sub), deadline);
        vm.prank(relayer);
        so.cancelFor(sub, subId, deadline, sig);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.SubscriptionInactive.selector, subId));
        so.cancelFor(sub, subId, deadline, sig);
    }

    function test_NonceIsSharedAndSequentialAcrossActions() public {
        uint256 planId = _plan();
        assertEq(so.nonces(sub), 0);
        uint256 subId = _relayedSubscribe(planId, 12);
        assertEq(so.nonces(sub), 1);

        // A cancel signed with the stale nonce 0 does not work, nonce 1 does.
        uint256 deadline = _deadline();
        bytes memory stale = _cancelSig(subKey, subId, 0, deadline);
        bytes memory fresh = _cancelSig(subKey, subId, 1, deadline);
        vm.prank(relayer);
        vm.expectRevert(StandingOrders.InvalidSigner.selector);
        so.cancelFor(sub, subId, deadline, stale);
        vm.prank(relayer);
        so.cancelFor(sub, subId, deadline, fresh);
        assertEq(so.nonces(sub), 2);
    }

    function test_MerchantAndSubscriberCanStillActDirectlyAfterRelayedSubscribe() public {
        uint256 planId = _plan();
        uint256 subId = _relayedSubscribe(planId, 12);
        vm.prank(merchant);
        so.cancel(subId); // merchant pays own gas
        assertFalse(so.subscription(subId).active);
    }

    // ------------------------------------------------------------ whole lifecycle

    function test_Lifecycle_SubscriberNeverNeedsAvax() public {
        uint256 planId = _plan();
        uint256 subId = _relayedSubscribe(planId, 3); // cap: 3 charges

        for (uint256 i = 0; i < 2; i++) {
            vm.warp(vm.getBlockTimestamp() + MONTH);
            uint256[] memory ids = new uint256[](1);
            ids[0] = subId;
            vm.prank(keeper);
            assertEq(so.chargeDue(ids), 1);
        }
        assertEq(usdc.balanceOf(merchant), uint256(PRICE) * 3);

        // Cap reached: no 4th charge even though a 12-period allowance was granted.
        vm.warp(vm.getBlockTimestamp() + MONTH);
        assertFalse(so.isDue(subId));
        assertGt(usdc.allowance(sub, address(so)), PRICE);

        uint256 deadline = _deadline();
        vm.prank(relayer);
        so.cancelFor(sub, subId, deadline, _cancelSig(subKey, subId, so.nonces(sub), deadline));

        assertEq(sub.balance, 0, "AVAX balance of subscriber: zero throughout");
        assertEq(usdc.balanceOf(address(so)), 0);
        assertEq(address(so).balance, 0);
    }

    function test_ContractRejectsNativeValue() public {
        (bool ok,) = address(so).call{value: 1}("");
        assertFalse(ok);
        (ok,) = address(so).call{value: 1}(abi.encodeCall(StandingOrders.cancel, (1)));
        assertFalse(ok);
        assertEq(address(so).balance, 0);
    }

    // ------------------------------------------------------------ fuzz

    /// A fresh signer, arbitrary plan terms: the relayed path always yields exactly the signer's subscription.
    function testFuzz_RelayedSubscribeAlwaysBelongsToSigner(uint256 key, uint96 price, uint32 period, uint32 cap)
        public
    {
        key = bound(key, 1, SECP256K1_N - 1);
        price = uint96(bound(price, 1, 1_000_000e6));
        period = uint32(bound(period, so.MIN_PERIOD(), so.MAX_PERIOD()));
        address signer = vm.addr(key);
        vm.assume(signer != sub && signer != merchant && signer != relayer);
        vm.assume(signer != address(so) && signer != address(usdc) && signer != address(this));
        vm.deal(signer, 0);
        usdc.mint(signer, uint256(price) * 2);

        vm.prank(merchant);
        uint256 planId = so.createPlan("Fuzz", price, period);

        uint256 deadline = _deadline();
        bytes memory sig = _subscribeSig(key, planId, cap, 0, deadline);
        StandingOrders.Permit memory permit = _permit(key, price, deadline);
        vm.prank(relayer);
        uint256 subId = so.subscribeWithPermitFor(signer, planId, cap, deadline, sig, permit);

        assertEq(so.subscription(subId).subscriber, signer);
        assertEq(so.subscription(subId).maxCharges, cap);
        assertEq(usdc.balanceOf(merchant), price);
        assertEq(usdc.balanceOf(signer), price);
        assertEq(signer.balance, 0);
    }

    /// Flipping any single byte of a valid signature must never produce a successful subscribe for a different state.
    function testFuzz_CorruptedSignatureNeverSubscribes(uint8 index, uint8 xorMask) public {
        vm.assume(xorMask != 0);
        uint256 planId = _plan();
        vm.prank(sub);
        usdc.approve(address(so), type(uint256).max);
        uint256 deadline = _deadline();
        bytes memory sig = _subscribeSig(subKey, planId, 0, 0, deadline);
        sig[index % 65] = bytes1(uint8(sig[index % 65]) ^ xorMask);

        vm.prank(relayer);
        try so.subscribeFor(sub, planId, 0, deadline, sig) returns (uint256) {
            revert("corrupted signature was accepted");
        } catch {}
        assertEq(so.subscriptionCount(), 0);
        assertEq(so.nonces(sub), 0);
    }
}
