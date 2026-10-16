// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TripFundV1} from "./TripFundV1.sol";

/// @notice Bonus V2 adds contributions on behalf of another participant without new storage.
/// @custom:oz-upgrades-from TripFundV1
contract TripFundV2 is TripFundV1 {
    event ContributedFor(address indexed payer, address indexed beneficiary, uint256 amount);

    /// @notice Pull the caller's tokens; the beneficiary owns the contribution and refund.
    function contributeFor(address beneficiary, uint256 amount) external {
        _contribute(msg.sender, beneficiary, amount);
        emit ContributedFor(msg.sender, beneficiary, amount);
    }
}
