// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StandingOrders, IUSDC} from "../src/StandingOrders.sol";

interface IUSDCView {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function version() external view returns (string memory);
    function decimals() external view returns (uint8);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function nonces(address owner) external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function blacklister() external view returns (address);
    function blacklist(address account) external;
    function isBlacklisted(address account) external view returns (bool);
}

/// @notice Checks against Circle's real USDC on Avalanche. These tests only run on a fork of
///         C-Chain mainnet (43114) or Fuji (43113) and are skipped elsewhere. Everything happens in
///         the local fork: nothing is broadcast, no real funds are touched.
///           forge test --match-contract AvalancheFork --fork-url https://api.avax.network/ext/bc/C/rpc
///           forge test --match-contract AvalancheFork --fork-url https://api.avax-test.network/ext/bc/C/rpc
contract AvalancheForkTest is Test {
    // Circle, "USDC contract addresses": https://developers.circle.com/stablecoins/usdc-contract-addresses
    address internal constant USDC_MAINNET = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant USDC_FUJI = 0x5425890298aed601595a70AB815c96711a31Bc65;

    uint96 internal constant PRICE = 2_500_000; // 2.50 USDC
    uint32 internal constant WEEK = 7 days;

    address internal merchant = makeAddr("merchant");
    address internal relayer = makeAddr("relayer");
    uint256 internal subKey = 0xC0DE;
    address internal sub;

    function _usdcAddress() internal view returns (address) {
        return block.chainid == 43_114 ? USDC_MAINNET : USDC_FUJI;
    }

    function _onAvalanche() internal view returns (bool) {
        return block.chainid == 43_114 || block.chainid == 43_113;
    }

    function setUp() public {
        sub = vm.addr(subKey);
    }

    /// The domain the web app / relayer signs permits with must match the real token.
    function test_UsdcPermitDomainMatchesWhatWeSign() public {
        if (!_onAvalanche()) vm.skip(true);
        IUSDCView usdc = IUSDCView(_usdcAddress());
        assertEq(usdc.decimals(), 6, "6 decimals");
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.name(), "USD Coin");
        assertEq(usdc.version(), "2");
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("USD Coin"),
                keccak256("2"),
                block.chainid,
                address(usdc)
            )
        );
        assertEq(usdc.DOMAIN_SEPARATOR(), expected);
    }

    function test_DeploysAgainstRealUsdc() public {
        if (!_onAvalanche()) vm.skip(true);
        StandingOrders so = new StandingOrders(IUSDC(_usdcAddress()));
        assertEq(address(so.usdc()), _usdcAddress());
    }

    /// Whole gasless lifecycle against the real token: real permit, real transferFrom.
    function test_GaslessLifecycleAgainstRealUsdc() public {
        if (!_onAvalanche()) vm.skip(true);
        IUSDCView usdc = IUSDCView(_usdcAddress());
        StandingOrders so = new StandingOrders(IUSDC(address(usdc)));

        deal(address(usdc), sub, 100e6);
        vm.deal(sub, 0);
        vm.deal(relayer, 1 ether);
        uint256 merchantBefore = usdc.balanceOf(merchant);
        assertEq(usdc.balanceOf(sub), 100e6, "deal() funded the subscriber");

        vm.prank(merchant);
        uint256 planId = so.createPlan("Weekly", PRICE, WEEK);

        // --- subscriber signs two messages offline; relayer submits one transaction
        uint256 deadline = vm.getBlockTimestamp() + 30 minutes;
        uint256 allowance = uint256(PRICE) * 4;
        bytes memory auth = _subscribeAuth(so, planId, 4, deadline);
        StandingOrders.Permit memory permit = _permit(usdc, so, allowance, deadline);

        vm.prank(relayer);
        uint256 subId = so.subscribeWithPermitFor(sub, planId, 4, deadline, auth, permit);

        assertEq(usdc.balanceOf(merchant) - merchantBefore, PRICE, "merchant received the first period");
        assertEq(usdc.balanceOf(sub), 100e6 - PRICE);
        assertEq(usdc.allowance(sub, address(so)), allowance - PRICE);
        assertEq(usdc.balanceOf(address(so)), 0);
        assertEq(sub.balance, 0, "subscriber holds no AVAX");
        assertEq(so.subscription(subId).subscriber, sub);

        // --- keeper charges the second period (anyone can)
        vm.warp(vm.getBlockTimestamp() + WEEK);
        uint256[] memory ids = new uint256[](1);
        ids[0] = subId;
        assertEq(so.chargeDue(ids), 1);
        assertEq(usdc.balanceOf(merchant) - merchantBefore, uint256(PRICE) * 2);

        // --- subscriber cancels without gas
        uint256 cancelDeadline = vm.getBlockTimestamp() + 30 minutes;
        bytes memory cancelSig = _cancelAuth(so, subId, cancelDeadline);
        vm.prank(relayer);
        so.cancelFor(sub, subId, cancelDeadline, cancelSig);
        assertFalse(so.subscription(subId).active);

        vm.warp(vm.getBlockTimestamp() + WEEK);
        assertFalse(so.isDue(subId));
        assertEq(usdc.balanceOf(merchant) - merchantBefore, uint256(PRICE) * 2, "nothing charged after cancel");
    }

    /// A subscriber who ran out of balance (or was blocklisted by Circle) must not block the batch.
    function test_RealUsdcBlocklistedSubscriberDoesNotBlockBatch() public {
        if (!_onAvalanche()) vm.skip(true);
        IUSDCView usdc = IUSDCView(_usdcAddress());
        StandingOrders so = new StandingOrders(IUSDC(address(usdc)));

        address good = makeAddr("good");
        address bad = makeAddr("bad");
        deal(address(usdc), good, 50e6);
        deal(address(usdc), bad, 50e6);
        vm.prank(merchant);
        uint256 planId = so.createPlan("Weekly", PRICE, WEEK);

        vm.startPrank(good);
        (bool ok,) =
            address(usdc).call(abi.encodeWithSignature("approve(address,uint256)", address(so), type(uint256).max));
        assertTrue(ok);
        uint256 goodId = so.subscribe(planId, 0);
        vm.stopPrank();
        vm.startPrank(bad);
        (ok,) = address(usdc).call(abi.encodeWithSignature("approve(address,uint256)", address(so), type(uint256).max));
        assertTrue(ok);
        uint256 badId = so.subscribe(planId, 0);
        vm.stopPrank();

        // Circle's blacklister blocklists `bad` (simulated in the fork only).
        vm.prank(usdc.blacklister());
        usdc.blacklist(bad);
        assertTrue(usdc.isBlacklisted(bad));

        vm.warp(vm.getBlockTimestamp() + WEEK);
        uint256[] memory ids = new uint256[](2);
        ids[0] = badId;
        ids[1] = goodId;
        assertEq(so.chargeDue(ids), 1, "good subscriber still charged");
        assertEq(so.subscription(goodId).chargeCount, 2);
        assertEq(so.subscription(badId).chargeCount, 1, "failed charge left no trace");
    }

    // ------------------------------------------------------------ helpers

    function _subscribeAuth(StandingOrders so, uint256 planId, uint32 cap, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 h = keccak256(abi.encode(so.SUBSCRIBE_TYPEHASH(), sub, planId, cap, so.nonces(sub), deadline));
        return _sign(subKey, _digest(so, h));
    }

    function _cancelAuth(StandingOrders so, uint256 subId, uint256 deadline) internal view returns (bytes memory) {
        bytes32 h = keccak256(abi.encode(so.CANCEL_TYPEHASH(), sub, subId, so.nonces(sub), deadline));
        return _sign(subKey, _digest(so, h));
    }

    function _digest(StandingOrders so, bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", so.DOMAIN_SEPARATOR(), structHash));
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// EIP-2612 permit signed against the REAL token's domain separator and nonce.
    function _permit(IUSDCView usdc, StandingOrders so, uint256 value, uint256 deadline)
        internal
        view
        returns (StandingOrders.Permit memory p)
    {
        bytes32 typehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(typehash, sub, address(so), value, usdc.nonces(sub), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(subKey, digest);
        p = StandingOrders.Permit({value: value, deadline: deadline, v: v, r: r, s: s});
    }
}
