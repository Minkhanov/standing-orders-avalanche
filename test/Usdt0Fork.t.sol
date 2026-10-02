// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StandingOrders, IUSDC} from "../src/StandingOrders.sol";

interface IToken {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function nonces(address owner) external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

// helper type alias kept so the copied helpers compile unchanged
interface IUSDCView is IToken {}

/// Local fork test of the UNCHANGED StandingOrders contract against Tether's real USDT0 (any chain in setUp).
///   forge test --match-contract Usdt0Fork --fork-url https://arb1.arbitrum.io/rpc
contract Usdt0ForkTest is Test {
    // Token addresses: https://docs.usdt0.to/technical-documentation/deployments (checked 2 Oct 2026)
    address internal USDT0;
    uint96 internal constant PRICE = 2_500_000; // 2.50 USDT0
    uint32 internal constant WEEK = 7 days;

    address internal merchant = makeAddr("merchant");
    address internal relayer = makeAddr("relayer");
    uint256 internal subKey = 0xC0DE;
    address internal sub;

    function setUp() public {
        sub = vm.addr(subKey);
        // Harness detail: on forks of OP-stack chains forge reverts calls sent by zero-balance accounts, so the
        // merchant and the payer get dust. The gasless subscriber never sends a transaction and stays at 0.
        vm.deal(merchant, 1 ether);
        uint256 id = block.chainid;
        if (id == 42_161) USDT0 = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9; // Arbitrum One
        else if (id == 10) USDT0 = 0x01bFF41798a0BcF287b996046Ca68b395DbC1071; // Optimism
        else if (id == 57_073) USDT0 = 0x0200C29006150606B650577BBE7B6248F58470c1; // Ink
        else if (id == 130) USDT0 = 0x9151434b16b9763660705744891fA906F660EcC5; // Unichain
        else if (id == 9745) USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb; // Plasma
        else if (id == 80_094) USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736; // Berachain
        else if (id == 988) USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736; // Stable
    }

    /// Runs only on a fork of one of the USDT0 chains above; skipped everywhere else.
    function _onUsdt0Chain() internal view returns (bool) {
        return USDT0 != address(0);
    }

    function test_Usdt0PermitDomain() public {
        if (!_onUsdt0Chain()) vm.skip(true);
        IToken t = IToken(USDT0);
        assertEq(t.decimals(), 6);
        // The name differs between chains ("USD₮0" with U+20AE on most, ASCII "USDT0" on Plasma and Stable),
        // and version() does not exist: so the signing domain must be read from the token, never hard-coded.
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(t.name())),
                keccak256("1"),
                block.chainid,
                USDT0
            )
        );
        assertEq(t.DOMAIN_SEPARATOR(), expected, "domain = (name(), version 1, chainId, token)");
    }

    function test_DeploysAgainstRealUsdt0() public {
        if (!_onUsdt0Chain()) vm.skip(true);
        StandingOrders so = new StandingOrders(IUSDC(USDT0));
        assertEq(address(so.usdc()), USDT0);
    }

    function test_GaslessLifecycleAgainstRealUsdt0() public {
        if (!_onUsdt0Chain()) vm.skip(true);
        IUSDCView usdc = IUSDCView(USDT0);
        StandingOrders so = new StandingOrders(IUSDC(address(usdc)));

        deal(address(usdc), sub, 100e6);
        vm.deal(sub, 0);
        vm.deal(relayer, 1 ether);
        uint256 merchantBefore = usdc.balanceOf(merchant);
        // The deterministic test-deployment address may already hold dust on the real chain; the contract
        // must not CHANGE its balance (it never holds funds).
        uint256 soBefore = usdc.balanceOf(address(so));
        assertEq(usdc.balanceOf(sub), 100e6, "deal() funded the subscriber");

        vm.prank(merchant);
        uint256 planId = so.createPlan("Weekly", PRICE, WEEK);

        uint256 deadline = vm.getBlockTimestamp() + 30 minutes;
        uint256 allowance = uint256(PRICE) * 4;
        bytes memory auth = _subscribeAuth(so, planId, 4, deadline);
        StandingOrders.Permit memory permit = _permit(usdc, so, allowance, deadline);

        vm.prank(relayer);
        uint256 subId = so.subscribeWithPermitFor(sub, planId, 4, deadline, auth, permit);

        assertEq(usdc.balanceOf(merchant) - merchantBefore, PRICE, "merchant received the first period");
        assertEq(usdc.balanceOf(sub), 100e6 - PRICE);
        assertEq(usdc.allowance(sub, address(so)), allowance - PRICE);
        assertEq(usdc.balanceOf(address(so)), soBefore, "contract holds nothing of its own");
        assertEq(sub.balance, 0, "subscriber holds no native gas token");

        vm.warp(vm.getBlockTimestamp() + WEEK);
        uint256[] memory ids = new uint256[](1);
        ids[0] = subId;
        assertEq(so.chargeDue(ids), 1);
        assertEq(usdc.balanceOf(merchant) - merchantBefore, uint256(PRICE) * 2);

        uint256 cancelDeadline = vm.getBlockTimestamp() + 30 minutes;
        bytes memory cancelSig = _cancelAuth(so, subId, cancelDeadline);
        vm.prank(relayer);
        so.cancelFor(sub, subId, cancelDeadline, cancelSig);
        assertFalse(so.subscription(subId).active);

        vm.warp(vm.getBlockTimestamp() + WEEK);
        assertFalse(so.isDue(subId));
        assertEq(usdc.balanceOf(merchant) - merchantBefore, uint256(PRICE) * 2, "nothing charged after cancel");
    }

    /// Plain path (what a WDK ERC-4337 smart account would use): approve + subscribe, no signatures.
    function test_ApproveThenSubscribeAgainstRealUsdt0() public {
        if (!_onUsdt0Chain()) vm.skip(true);
        IUSDCView usdc = IUSDCView(USDT0);
        StandingOrders so = new StandingOrders(IUSDC(address(usdc)));
        address payer = makeAddr("payer");
        vm.deal(payer, 1 ether);
        deal(address(usdc), payer, 50e6);
        vm.prank(merchant);
        uint256 planId = so.createPlan("Weekly", PRICE, WEEK);
        vm.startPrank(payer);
        (bool ok,) =
            address(usdc).call(abi.encodeWithSignature("approve(address,uint256)", address(so), uint256(PRICE) * 3));
        assertTrue(ok);
        uint256 subId = so.subscribe(planId, 3);
        vm.stopPrank();
        assertEq(usdc.balanceOf(merchant), PRICE);
        vm.warp(vm.getBlockTimestamp() + WEEK);
        uint256[] memory ids = new uint256[](1);
        ids[0] = subId;
        assertEq(so.chargeDue(ids), 1);
        vm.warp(vm.getBlockTimestamp() + WEEK);
        assertEq(so.chargeDue(ids), 1);
        vm.warp(vm.getBlockTimestamp() + WEEK);
        assertEq(so.chargeDue(ids), 0, "cap of 3 holds");
        assertEq(usdc.balanceOf(merchant), uint256(PRICE) * 3);
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
