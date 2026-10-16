// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {TripFundCore} from "./TripFundCore.sol";

/// @notice Bonus V1, deployed and initialized through a TransparentUpgradeableProxy.
contract TripFundV1 is Initializable, TripFundCore {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20 token_, address organizer_, uint256 goal_, uint256 deadline_)
        external
        initializer
    {
        _initializeFund(token_, organizer_, goal_, deadline_);
    }
}
