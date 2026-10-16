// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TripFund} from "../src/TripFund.sol";

contract DeployTripFund is Script {
    function run() external returns (TripFund fund) {
        IERC20 token = IERC20(vm.envAddress("TOKEN"));
        address organizer = vm.envAddress("ORGANIZER");
        uint256 goal = vm.envUint("GOAL");
        uint256 deadline = vm.envUint("DEADLINE");

        vm.startBroadcast();
        fund = new TripFund(token, organizer, goal, deadline);
        vm.stopBroadcast();
    }
}
