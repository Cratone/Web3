// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Shared accounting for the constructor-based fund and the proxy implementations.
/// @dev Supports ERC-20 tokens without transfer fees or rebasing.
abstract contract TripFundCore {
    using SafeERC20 for IERC20;

    IERC20 public token;
    address public organizer;
    uint256 public goal;
    uint256 public deadline;
    mapping(address contributor => uint256 amount) public contributions;
    // Historical total: withdrawals and refunds never decrease it.
    uint256 public totalRaised;
    bool public withdrawn;

    error ZeroAddress();
    error ZeroGoal();
    error InvalidDeadline();
    error ZeroAmount();
    error FundClosed();
    error DeadlineNotReached();
    error NotOrganizer();
    error GoalNotReached();
    error GoalReached();
    error AlreadyWithdrawn();
    error NoContribution();

    event Contributed(address indexed contributor, uint256 amount);
    event Refunded(address indexed contributor, uint256 amount);
    event Withdrawn(address indexed organizer, uint256 amount);

    function _initializeFund(IERC20 token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
    {
        if (address(token_) == address(0) || organizer_ == address(0)) revert ZeroAddress();
        if (goal_ == 0) revert ZeroGoal();
        if (deadline_ <= block.timestamp) revert InvalidDeadline();

        token = token_;
        organizer = organizer_;
        goal = goal_;
        deadline = deadline_;
    }

    /// @notice Pull tokens previously approved by the caller and credit their contribution.
    function contribute(uint256 amount) external {
        _contribute(msg.sender, msg.sender, amount);
        emit Contributed(msg.sender, amount);
    }

    /// @dev Effects precede the external transfer; a failed transfer reverts all effects.
    function _contribute(address payer, address beneficiary, uint256 amount) internal {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp >= deadline) revert FundClosed();

        contributions[beneficiary] += amount;
        totalRaised += amount;
        token.safeTransferFrom(payer, address(this), amount);
    }

    /// @notice Pay exactly the accounted total, leaving unsolicited transfers in the fund.
    function withdraw() external {
        if (block.timestamp < deadline) revert DeadlineNotReached();
        if (msg.sender != organizer) revert NotOrganizer();
        if (totalRaised < goal) revert GoalNotReached();
        if (withdrawn) revert AlreadyWithdrawn();

        withdrawn = true;
        uint256 amount = totalRaised;
        token.safeTransfer(organizer, amount);
        emit Withdrawn(organizer, amount);
    }

    /// @notice Return the caller's entire contribution only if the campaign failed.
    function refund() external {
        if (block.timestamp < deadline) revert DeadlineNotReached();
        if (totalRaised >= goal) revert GoalReached();

        uint256 amount = contributions[msg.sender];
        if (amount == 0) revert NoContribution();

        contributions[msg.sender] = 0;
        token.safeTransfer(msg.sender, amount);
        emit Refunded(msg.sender, amount);
    }
}
