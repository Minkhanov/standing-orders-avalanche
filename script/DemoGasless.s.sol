// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {StandingOrders} from "../src/StandingOrders.sol";

interface IFiatToken {
    function nonces(address owner) external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @notice End-to-end demo of the gasless flow on Fuji with Circle's test USDC.
///
///   PRIVATE_KEY             merchant + relayer (pays all gas, needs a little test AVAX)
///   SUBSCRIBER_PRIVATE_KEY  payer: holds test USDC, must hold NO AVAX
///   STANDING_ORDERS         deployed contract
///
///   forge script script/DemoGasless.s.sol:DemoGasless --sig "plan()"            --rpc-url fuji --broadcast
///   forge script script/DemoGasless.s.sol:DemoGasless --sig "subscribe(uint256)" 1 --rpc-url fuji --broadcast
///   (wait one period: 60 s) forge script ... --sig "charge(uint256)" 1 --gas-limit 500000 --rpc-url fuji --broadcast
///   forge script script/DemoGasless.s.sol:DemoGasless --sig "cancel(uint256)" 1 --rpc-url fuji --broadcast
///
///   The subscriber key is only used to SIGN (vm.sign); it never sends a transaction.
contract DemoGasless is Script {
    uint96 internal constant PRICE = 1_000_000; // 1.00 USDC
    uint32 internal constant CAP = 3; // at most 3 charges
    uint32 internal constant PERIOD = 60; // 60 s, the contract's minimum, so a renewal can be shown live

    function _so() internal view returns (StandingOrders) {
        require(block.chainid == 43_113, "DemoGasless: Fuji only");
        return StandingOrders(vm.envAddress("STANDING_ORDERS"));
    }

    /// Merchant publishes a plan.
    function plan() external {
        StandingOrders so = _so();
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        uint256 planId = so.createPlan("Demo weekly (60s)", PRICE, PERIOD);
        vm.stopBroadcast();
        console2.log("planId:", planId);
    }

    /// Subscriber signs offline (permit + Subscribe); the relayer sends one transaction.
    function subscribe(uint256 planId) external {
        StandingOrders so = _so();
        uint256 subKey = vm.envUint("SUBSCRIBER_PRIVATE_KEY");
        address sub = vm.addr(subKey);
        IFiatToken usdc = IFiatToken(address(so.usdc()));

        console2.log("subscriber:", sub);
        console2.log("subscriber AVAX balance (wei):", sub.balance);
        console2.log("subscriber USDC balance (6 dp):", usdc.balanceOf(sub));
        require(usdc.balanceOf(sub) >= uint256(PRICE) * 3, "fund the subscriber with test USDC first");
        require(sub.balance == 0, "the point of the demo: the subscriber must hold no AVAX");

        uint256 deadline = block.timestamp + 30 minutes;
        StandingOrders.Permit memory permit = _signPermit(so, usdc, subKey, uint256(PRICE) * CAP, deadline);
        bytes memory auth = _signSubscribe(so, subKey, planId, deadline);

        // The relayer (merchant key) broadcasts; the subscriber key signs but never sends a tx.
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        uint256 subId = so.subscribeWithPermitFor(sub, planId, CAP, deadline, auth, permit);
        vm.stopBroadcast();
        console2.log("subscriptionId:", subId);
    }

    /// EIP-2612 permit: subscriber -> StandingOrders, enough for `CAP` charges.
    function _signPermit(StandingOrders so, IFiatToken usdc, uint256 subKey, uint256 value, uint256 deadline)
        internal
        view
        returns (StandingOrders.Permit memory p)
    {
        address sub = vm.addr(subKey);
        bytes32 h = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                sub,
                address(so),
                value,
                usdc.nonces(sub),
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(subKey, keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), h)));
        p = StandingOrders.Permit({value: value, deadline: deadline, v: v, r: r, s: s});
    }

    /// EIP-712 Subscribe message bound to this plan, cap, nonce and deadline.
    function _signSubscribe(StandingOrders so, uint256 subKey, uint256 planId, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        address sub = vm.addr(subKey);
        bytes32 h = keccak256(abi.encode(so.SUBSCRIBE_TYPEHASH(), sub, planId, CAP, so.nonces(sub), deadline));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(subKey, keccak256(abi.encodePacked("\x19\x01", so.DOMAIN_SEPARATOR(), h)));
        return abi.encodePacked(r, s, v);
    }

    /// Keeper pulls the next period (anyone can call). Run it with an explicit `--gas-limit 500000`:
    /// forge sizes the gas from a simulation at the latest block, and on a quiet testnet that block can
    /// predate the due time, so the simulation takes the cheap "not due yet" path.
    /// `scripts/fuji-run-all.sh` sends this call with `cast send --gas-limit` instead.
    function charge(uint256 subId) external {
        StandingOrders so = _so();
        uint256[] memory ids = new uint256[](1);
        ids[0] = subId;
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        uint256 charged = so.chargeDue(ids);
        vm.stopBroadcast();
        console2.log("charged:", charged);
    }

    /// Subscriber cancels with a signature; the relayer pays the gas.
    function cancel(uint256 subId) external {
        StandingOrders so = _so();
        uint256 subKey = vm.envUint("SUBSCRIBER_PRIVATE_KEY");
        address sub = vm.addr(subKey);
        uint256 deadline = block.timestamp + 30 minutes;
        bytes32 h = keccak256(abi.encode(so.CANCEL_TYPEHASH(), sub, subId, so.nonces(sub), deadline));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(subKey, keccak256(abi.encodePacked("\x19\x01", so.DOMAIN_SEPARATOR(), h)));
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        so.cancelFor(sub, subId, deadline, abi.encodePacked(r, s, v));
        vm.stopBroadcast();
        console2.log("cancelled:", subId);
    }
}
