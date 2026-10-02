// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {StandingOrders, IUSDC} from "../src/StandingOrders.sol";

interface IToken {
    function name() external view returns (string memory);
    function version() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @notice Deploys StandingOrders against Circle's native USDC on Avalanche C-Chain.
///         The token address is chosen by chain id from Circle's published table, never from user input:
///         https://developers.circle.com/stablecoins/usdc-contract-addresses
///
///         Fuji testnet (43113):
///           forge script script/Deploy.s.sol:Deploy --rpc-url fuji --private-key $PRIVATE_KEY --broadcast
///         Mainnet (43114) additionally needs ALLOW_MAINNET=true, so a mainnet broadcast can never happen by accident.
contract Deploy is Script {
    address internal constant USDC_MAINNET = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E; // C-Chain, 43114
    address internal constant USDC_FUJI = 0x5425890298aed601595a70AB815c96711a31Bc65; // Fuji, 43113

    function run() external returns (StandingOrders so) {
        address usdc;
        if (block.chainid == 43_114) {
            require(vm.envOr("ALLOW_MAINNET", false), "Deploy: mainnet needs ALLOW_MAINNET=true");
            usdc = USDC_MAINNET;
        } else if (block.chainid == 43_113) {
            usdc = USDC_FUJI;
        } else {
            revert("Deploy: not Avalanche C-Chain (43114) or Fuji (43113); use DeployLocal");
        }

        // The permit domain we sign against must be the one the chain's USDC really uses.
        require(keccak256(bytes(IToken(usdc).name())) == keccak256("USD Coin"), "Deploy: unexpected token name");
        require(keccak256(bytes(IToken(usdc).version())) == keccak256("2"), "Deploy: unexpected token version");
        require(IToken(usdc).decimals() == 6, "Deploy: unexpected token decimals");

        vm.startBroadcast();
        so = new StandingOrders(IUSDC(usdc));
        vm.stopBroadcast();

        console2.log("StandingOrders deployed at:", address(so));
        console2.log("USDC:", usdc);
        console2.log("Chain id:", block.chainid);
        console2.log("EIP-712 domain separator:");
        console2.logBytes32(so.DOMAIN_SEPARATOR());
    }
}
