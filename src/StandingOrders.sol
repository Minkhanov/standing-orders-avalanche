// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Minimal view of Circle's native USDC on Avalanche C-Chain (FiatToken v2: 6 decimals, EIP-2612
///      permit, EIP-712 domain name "USD Coin", version "2").
///      Mainnet 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E, Fuji 0x5425890298aed601595a70AB815c96711a31Bc65.
interface IUSDC {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
}

/// @title StandingOrders — recurring USDC payments (subscriptions) for Avalanche C-Chain
/// @notice A merchant publishes a plan: a fixed USDC price per fixed period. A subscriber
///         authorises the contract to pull that price once per period (ERC-20 allowance or an
///         EIP-2612 signature) and pays the first period immediately. After that anyone — the
///         merchant, a keeper bot, or the subscriber — can trigger a charge once it is due.
///
///         Gasless for the subscriber: the subscriber can sign an EIP-2612 permit (allowance) and an
///         EIP-712 `Subscribe` message off-chain; the merchant (or any relayer) submits both in one
///         transaction and pays the AVAX gas. The subscriber needs USDC only. Cancelling is gasless
///         too, with a signed `Cancel` message.
/// @dev    Safety properties, all enforced on-chain:
///         - plan terms (merchant, price, period) are immutable, so a merchant can never raise a
///           price on existing subscribers;
///         - at most one charge per period, never before `nextChargeAt`;
///         - missed periods are skipped, never back-charged in bulk;
///         - each subscription carries its own cap (`maxCharges`), independent of the ERC-20
///           allowance, which is shared by all of a wallet's subscriptions to this contract;
///         - the subscriber (or the merchant) can cancel at any time;
///         - funds go straight from subscriber to merchant: the contract holds no USDC, has no
///           payable functions and never moves native value, so the ERC-20 allowance is the
///           complete spending cap;
///         - relayed actions are bound to the subscriber's signature over every parameter, the
///           chain id and this contract's address, plus a per-subscriber nonce and a deadline. A
///           relayer can submit or withhold a signed message but cannot alter or replay it.
///
///         Design note (why not ERC-2771): a trusted forwarder changes `msg.sender` semantics for the
///         whole contract and adds a second contract to trust. Verifying one typed signature inside
///         the two functions that need it is smaller and has a narrower attack surface.
contract StandingOrders {
    uint32 public constant MIN_PERIOD = 60; // 1 minute — lets demos show a real renewal
    uint32 public constant MAX_PERIOD = 366 days;
    uint256 public constant MAX_NAME_BYTES = 64;

    // ---- EIP-712 (relayed actions)
    string public constant NAME = "StandingOrders";
    string public constant VERSION = "1";
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    /// @notice Typed data a subscriber signs to let someone else subscribe on their behalf.
    bytes32 public constant SUBSCRIBE_TYPEHASH =
        keccak256("Subscribe(address subscriber,uint256 planId,uint32 maxCharges,uint256 nonce,uint256 deadline)");
    /// @notice Typed data a subscriber signs to let someone else cancel on their behalf.
    bytes32 public constant CANCEL_TYPEHASH =
        keccak256("Cancel(address subscriber,uint256 subscriptionId,uint256 nonce,uint256 deadline)");
    /// @dev Upper bound of a valid ECDSA `s` (secp256k1 n/2); rejects the malleable twin signature.
    uint256 private constant _HALF_CURVE_ORDER = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    IUSDC public immutable usdc;
    uint256 private immutable _cachedChainId;
    bytes32 private immutable _cachedDomainSeparator;

    struct Plan {
        address merchant;
        uint96 price; // USDC base units (6 decimals, ERC-20 interface)
        uint32 period; // seconds
        bool active;
        string name;
    }

    struct Subscription {
        address subscriber;
        uint64 planId;
        uint32 chargeCount; // charges made so far, including the first one at subscribe time
        uint64 nextChargeAt;
        uint64 startedAt;
        uint32 maxCharges; // hard cap on the number of charges; 0 = no cap (allowance still applies)
        bool active;
    }

    uint256 public planCount; // plan ids start at 1
    uint256 public subscriptionCount; // subscription ids start at 1

    mapping(uint256 => Plan) private _plans;
    mapping(uint256 => Subscription) private _subs;
    mapping(address => uint256[]) private _plansOfMerchant;
    mapping(uint256 => uint256[]) private _subsOfPlan;
    mapping(address => uint256[]) private _subsOfSubscriber;

    /// @notice subscriber => planId => active subscription id (0 = none).
    mapping(address => mapping(uint256 => uint256)) public activeSubscriptionOf;

    /// @notice Next valid nonce of a subscriber for relayed (signed) actions. Shared by `Subscribe`
    ///         and `Cancel` messages; consumed on use, so every signature works exactly once.
    mapping(address => uint256) public nonces;

    /// @notice Arguments of the EIP-2612 `permit` call on USDC (owner = subscriber, spender = this contract).
    struct Permit {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    event PlanCreated(uint256 indexed planId, address indexed merchant, uint256 price, uint32 period, string name);
    event PlanStatusChanged(uint256 indexed planId, bool active);
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

    error InvalidToken();
    error InvalidPrice();
    error InvalidPeriod();
    error InvalidName();
    error UnknownPlan(uint256 planId);
    error NotMerchant();
    error PlanInactive(uint256 planId);
    error AlreadySubscribed(uint256 subscriptionId);
    error UnknownSubscription(uint256 subscriptionId);
    error SubscriptionInactive(uint256 subscriptionId);
    error NotDue(uint64 nextChargeAt);
    error CapReached(uint256 subscriptionId);
    error NotAuthorized();
    error TransferFailed();
    error SignatureExpired(uint256 deadline);
    error InvalidSignature();
    error InvalidSigner();
    error InvalidSubscriber();

    constructor(IUSDC _usdc) {
        if (address(_usdc).code.length == 0) revert InvalidToken();
        usdc = _usdc;
        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _buildDomainSeparator();
    }

    // ------------------------------------------------------------------ merchant

    /// @notice Publish a plan. Terms can never change afterwards; publish a new plan instead.
    function createPlan(string calldata name, uint96 price, uint32 period) external returns (uint256 planId) {
        if (price == 0) revert InvalidPrice();
        if (period < MIN_PERIOD || period > MAX_PERIOD) revert InvalidPeriod();
        uint256 len = bytes(name).length;
        if (len == 0 || len > MAX_NAME_BYTES) revert InvalidName();

        planId = ++planCount;
        _plans[planId] = Plan({merchant: msg.sender, price: price, period: period, active: true, name: name});
        _plansOfMerchant[msg.sender].push(planId);
        emit PlanCreated(planId, msg.sender, price, period, name);
    }

    /// @notice Pause or resume a plan. A paused plan accepts no new subscribers and no charges.
    function setPlanActive(uint256 planId, bool active) external {
        Plan storage p = _existingPlan(planId);
        if (msg.sender != p.merchant) revert NotMerchant();
        p.active = active;
        emit PlanStatusChanged(planId, active);
    }

    // ------------------------------------------------------------------ subscriber

    /// @notice Subscribe using an existing USDC allowance; the first period is charged now.
    /// @param maxCharges Maximum number of charges including the first one (0 = no cap).
    function subscribe(uint256 planId, uint32 maxCharges) external returns (uint256 subscriptionId) {
        return _subscribe(msg.sender, planId, maxCharges);
    }

    /// @notice One-transaction subscribe: sets the allowance with an EIP-2612 signature, then
    ///         subscribes. The permit is wrapped in try/catch so a front-run of the same signature
    ///         cannot block the subscription (the allowance is already in place in that case).
    function subscribeWithPermit(
        uint256 planId,
        uint32 maxCharges,
        uint256 allowance,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 subscriptionId) {
        try usdc.permit(msg.sender, address(this), allowance, deadline, v, r, s) {} catch {}
        return _subscribe(msg.sender, planId, maxCharges);
    }

    /// @notice Stop all future charges. Callable by the subscriber or the plan's merchant.
    function cancel(uint256 subscriptionId) external {
        Subscription storage s = _existingSub(subscriptionId);
        if (!s.active) revert SubscriptionInactive(subscriptionId);
        if (msg.sender != s.subscriber && msg.sender != _plans[s.planId].merchant) revert NotAuthorized();
        _cancel(subscriptionId, s, msg.sender);
    }

    // ------------------------------------------------------------------ gasless (relayed) actions

    /// @notice Gasless subscribe, using an allowance the subscriber already granted. Anyone (typically
    ///         the merchant) may submit; the subscriber only signs an EIP-712 `Subscribe` message.
    /// @param subscriber The wallet that signed. The first period is charged to this wallet.
    /// @param deadline   Unix time after which the signature is void.
    /// @param signature  65-byte (r, s, v) signature of `Subscribe(subscriber, planId, maxCharges, nonce, deadline)`
    ///                   with `nonce = nonces(subscriber)`.
    function subscribeFor(
        address subscriber,
        uint256 planId,
        uint32 maxCharges,
        uint256 deadline,
        bytes calldata signature
    ) external returns (uint256 subscriptionId) {
        _consumeSubscribeSignature(subscriber, planId, maxCharges, deadline, signature);
        return _subscribe(subscriber, planId, maxCharges);
    }

    /// @notice Fully gasless subscribe: sets the allowance with the subscriber's EIP-2612 signature,
    ///         verifies the `Subscribe` signature and subscribes, all in one transaction paid by the
    ///         submitter. The permit is wrapped in try/catch so a front-run of the same permit
    ///         signature cannot block the subscription (the allowance is already in place then).
    function subscribeWithPermitFor(
        address subscriber,
        uint256 planId,
        uint32 maxCharges,
        uint256 deadline,
        bytes calldata signature,
        Permit calldata permit
    ) external returns (uint256 subscriptionId) {
        _consumeSubscribeSignature(subscriber, planId, maxCharges, deadline, signature);
        try usdc.permit(subscriber, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s) {}
            catch {}
        return _subscribe(subscriber, planId, maxCharges);
    }

    /// @notice Gasless cancel: anyone can submit the subscriber's signed `Cancel` message.
    /// @param signature 65-byte (r, s, v) signature of `Cancel(subscriber, subscriptionId, nonce, deadline)`
    ///                  with `nonce = nonces(subscriber)`.
    function cancelFor(address subscriber, uint256 subscriptionId, uint256 deadline, bytes calldata signature)
        external
    {
        Subscription storage s = _existingSub(subscriptionId);
        if (!s.active) revert SubscriptionInactive(subscriptionId);
        if (s.subscriber != subscriber) revert InvalidSubscriber();
        _checkDeadline(deadline);
        _verifyAndConsume(
            subscriber,
            keccak256(abi.encode(CANCEL_TYPEHASH, subscriber, subscriptionId, nonces[subscriber], deadline)),
            signature
        );
        _cancel(subscriptionId, s, subscriber);
    }

    // ------------------------------------------------------------------ charging (permissionless)

    /// @notice Charge one due subscription. Anyone may call; funds always go to the merchant.
    function charge(uint256 subscriptionId) public {
        Subscription storage s = _existingSub(subscriptionId);
        if (!s.active) revert SubscriptionInactive(subscriptionId);
        Plan storage p = _plans[s.planId];
        if (!p.active) revert PlanInactive(s.planId);
        // Periods are minutes to months; proposer timestamp skew does not matter here.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < s.nextChargeAt) revert NotDue(s.nextChargeAt);
        if (s.maxCharges != 0 && s.chargeCount >= s.maxCharges) revert CapReached(subscriptionId);

        uint64 next = s.nextChargeAt + p.period;
        // Missed periods are skipped rather than back-charged in bulk.
        // forge-lint: disable-next-line(block-timestamp)
        if (next <= block.timestamp) next = _now() + p.period;
        s.nextChargeAt = next;
        s.chargeCount += 1;

        emit Charged(subscriptionId, s.planId, s.subscriber, p.merchant, p.price, s.chargeCount, next);
        _pull(s.subscriber, p.merchant, p.price);
    }

    /// @notice Charge every due subscription in `ids`; failures (e.g. allowance ran out) are
    ///         reported with `ChargeFailed` and skipped. Ids that are not due are ignored.
    function chargeDue(uint256[] calldata ids) external returns (uint256 charged) {
        for (uint256 i = 0; i < ids.length; i++) {
            if (!isDue(ids[i])) continue;
            // The self-call isolates each charge: a failing subscriber cannot block the batch.
            // forge-lint: disable-next-line(calls-loop)
            try this.charge(ids[i]) {
                charged++;
            } catch (bytes memory reason) {
                // forge-lint: disable-next-line(reentrancy-events)
                emit ChargeFailed(ids[i], reason);
            }
        }
    }

    // ------------------------------------------------------------------ views

    /// @notice EIP-712 domain separator of this deployment (follows `block.chainid` after a chain fork).
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == _cachedChainId ? _cachedDomainSeparator : _buildDomainSeparator();
    }

    function plan(uint256 planId) external view returns (Plan memory) {
        return _plans[planId];
    }

    function subscription(uint256 subscriptionId) external view returns (Subscription memory) {
        return _subs[subscriptionId];
    }

    /// @notice True if the subscription can be charged right now.
    function isDue(uint256 subscriptionId) public view returns (bool) {
        Subscription storage s = _subs[subscriptionId];
        if (s.maxCharges != 0 && s.chargeCount >= s.maxCharges) return false;
        // forge-lint: disable-next-line(block-timestamp)
        return s.active && _plans[s.planId].active && block.timestamp >= s.nextChargeAt;
    }

    function plansOf(address merchant) external view returns (uint256[] memory) {
        return _plansOfMerchant[merchant];
    }

    function subscriptionsOf(address subscriber) external view returns (uint256[] memory) {
        return _subsOfSubscriber[subscriber];
    }

    function subscriptionCountOfPlan(uint256 planId) external view returns (uint256) {
        return _subsOfPlan[planId].length;
    }

    /// @notice Page through all subscriptions of a plan (oldest first, including cancelled).
    function subscriptionsOfPlan(uint256 planId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids)
    {
        return _page(_subsOfPlan[planId], offset, limit);
    }

    /// @notice Due subscription ids of a plan within a page — what a keeper passes to `chargeDue`.
    function dueSubscriptionsOfPlan(uint256 planId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory due)
    {
        uint256[] memory page = _page(_subsOfPlan[planId], offset, limit);
        uint256 n = 0;
        for (uint256 i = 0; i < page.length; i++) {
            if (isDue(page[i])) page[n++] = page[i];
        }
        due = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            due[i] = page[i];
        }
    }

    // ------------------------------------------------------------------ internals

    function _subscribe(address subscriber, uint256 planId, uint32 maxCharges)
        internal
        returns (uint256 subscriptionId)
    {
        Plan storage p = _existingPlan(planId);
        if (!p.active) revert PlanInactive(planId);
        uint256 existing = activeSubscriptionOf[subscriber][planId];
        if (existing != 0) revert AlreadySubscribed(existing);

        subscriptionId = ++subscriptionCount;
        uint64 nowTs = _now();
        uint64 next = nowTs + p.period;
        _subs[subscriptionId] = Subscription({
            subscriber: subscriber,
            // planId <= planCount, far below 2^64.
            // forge-lint: disable-next-line(unsafe-typecast)
            planId: uint64(planId),
            chargeCount: 1,
            nextChargeAt: next,
            startedAt: nowTs,
            maxCharges: maxCharges,
            active: true
        });
        activeSubscriptionOf[subscriber][planId] = subscriptionId;
        _subsOfPlan[planId].push(subscriptionId);
        _subsOfSubscriber[subscriber].push(subscriptionId);

        // The only earlier external call is USDC.permit (trusted token, permit paths).
        // forge-lint: disable-next-line(reentrancy-events)
        emit Subscribed(subscriptionId, planId, subscriber);
        // forge-lint: disable-next-line(reentrancy-events)
        emit Charged(subscriptionId, planId, subscriber, p.merchant, p.price, 1, next);
        _pull(subscriber, p.merchant, p.price);
    }

    function _cancel(uint256 subscriptionId, Subscription storage s, address by) private {
        s.active = false;
        delete activeSubscriptionOf[s.subscriber][s.planId];
        emit Cancelled(subscriptionId, by);
    }

    // ---- signature handling

    function _consumeSubscribeSignature(
        address subscriber,
        uint256 planId,
        uint32 maxCharges,
        uint256 deadline,
        bytes calldata signature
    ) private {
        _checkDeadline(deadline);
        _verifyAndConsume(
            subscriber,
            keccak256(abi.encode(SUBSCRIBE_TYPEHASH, subscriber, planId, maxCharges, nonces[subscriber], deadline)),
            signature
        );
    }

    function _checkDeadline(uint256 deadline) private view {
        // Signature windows are minutes to hours; proposer timestamp skew does not matter here.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert SignatureExpired(deadline);
    }

    /// @dev Verifies an EIP-712 signature by `signer` over `structHash` and consumes the nonce
    ///      (`structHash` must have been built with the current `nonces[signer]`).
    function _verifyAndConsume(address signer, bytes32 structHash, bytes calldata signature) private {
        if (signer == address(0)) revert InvalidSigner();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
        if (_recover(digest, signature) != signer) revert InvalidSigner();
        nonces[signer]++;
    }

    /// @dev Strict ECDSA recovery: 65 bytes, v in {27, 28}, low-s, non-zero result.
    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address signer) {
        if (signature.length != 65) revert InvalidSignature();
        bytes32 r = bytes32(signature[0:32]);
        bytes32 s = bytes32(signature[32:64]);
        uint8 v = uint8(signature[64]);
        if ((v != 27 && v != 28) || uint256(s) > _HALF_CURVE_ORDER) revert InvalidSignature();
        signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _DOMAIN_TYPEHASH, keccak256(bytes(NAME)), keccak256(bytes(VERSION)), block.chainid, address(this)
            )
        );
    }

    /// @dev transferFrom that tolerates tokens returning nothing and bubbles the token's revert
    ///      reason (e.g. "ERC20: transfer amount exceeds allowance") for clear UI errors.
    function _pull(address from, address to, uint256 amount) private {
        (bool ok, bytes memory ret) = address(usdc).call(abi.encodeCall(IUSDC.transferFrom, (from, to, amount)));
        if (!ok) {
            if (ret.length == 0) revert TransferFailed();
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        if (ret.length != 0 && !abi.decode(ret, (bool))) revert TransferFailed();
    }

    function _existingPlan(uint256 planId) private view returns (Plan storage p) {
        p = _plans[planId];
        if (p.merchant == address(0)) revert UnknownPlan(planId);
    }

    function _existingSub(uint256 subscriptionId) private view returns (Subscription storage s) {
        s = _subs[subscriptionId];
        if (s.subscriber == address(0)) revert UnknownSubscription(subscriptionId);
    }

    function _now() private view returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(block.timestamp);
    }

    function _page(uint256[] storage all, uint256 offset, uint256 limit) private view returns (uint256[] memory ids) {
        if (offset >= all.length) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > all.length) end = all.length;
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            ids[i - offset] = all[i];
        }
    }
}
