// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TripFundCore} from "./TripFundCore.sol";

/// @notice Basic homework variant: parameters are set once in the constructor.
contract TripFund is TripFundCore {
    constructor(IERC20 token_, address organizer_, uint256 goal_, uint256 deadline_) {
        _initializeFund(token_, organizer_, goal_, deadline_);
    }
}
