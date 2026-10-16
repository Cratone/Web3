// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TripFundV1} from "../src/TripFundV1.sol";

contract DeployTripFundProxy is Script {
    function run() external returns (TransparentUpgradeableProxy proxy) {
        IERC20 token = IERC20(vm.envAddress("TOKEN"));
        address organizer = vm.envAddress("ORGANIZER");
        uint256 goal = vm.envUint("GOAL");
        uint256 deadline = vm.envUint("DEADLINE");
        address adminOwner = vm.envAddress("PROXY_ADMIN_OWNER");

        vm.startBroadcast();
        TripFundV1 implementation = new TripFundV1();
        proxy = new TransparentUpgradeableProxy(
            address(implementation),
            adminOwner,
            abi.encodeCall(TripFundV1.initialize, (token, organizer, goal, deadline))
        );
        vm.stopBroadcast();
    }
}
