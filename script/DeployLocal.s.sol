// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {StandingOrders, IUSDC} from "../src/StandingOrders.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

/// @notice LOCAL ONLY (anvil): deploys a mock USDC, funds anvil's dev accounts 1..5 with 1,000
///         mock USDC each and deploys StandingOrders.
///         anvil &  forge script script/DeployLocal.s.sol:DeployLocal --rpc-url local \
///           --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast
contract DeployLocal is Script {
    function run() external returns (StandingOrders so, MockUSDC usdc) {
        require(block.chainid == 31_337, "DeployLocal: anvil only");
        vm.startBroadcast();
        usdc = new MockUSDC();
        so = new StandingOrders(IUSDC(address(usdc)));
        address[5] memory devs = [
            0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,
            0x90F79bf6EB2c4f870365E785982E1f101E93b906,
            0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65,
            0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
        ];
        for (uint256 i = 0; i < devs.length; i++) {
            usdc.mint(devs[i], 1_000e6);
        }
        vm.stopBroadcast();
        console2.log("MockUSDC deployed at:", address(usdc));
        console2.log("StandingOrders deployed at:", address(so));
    }
}
