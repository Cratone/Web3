// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Local testing token: standard ERC-20, 18 decimals, no fees and no rebasing.
/// @dev Unrestricted minting is intentionally for local tests and demonstrations only.
contract MockTripToken is ERC20 {
    constructor() ERC20("Trip Token", "TRIP") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
