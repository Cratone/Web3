// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TripFundCore} from "../src/TripFundCore.sol";
import {TripFund} from "../src/TripFund.sol";
import {TripFundV1} from "../src/TripFundV1.sol";
import {TripFundV2} from "../src/TripFundV2.sol";
import {MockTripToken} from "../src/MockTripToken.sol";

/// @dev A false return must trigger SafeERC20's revert and restore the fund's accounting.
contract FailingTripToken is MockTripToken {
    bool public failTransfer;
    bool public failTransferFrom;

    function setFailures(bool transfer_, bool transferFrom_) external {
        failTransfer = transfer_;
        failTransferFrom = transferFrom_;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (failTransfer) return false;
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (failTransferFrom) return false;
        return super.transferFrom(from, to, value);
    }
}

/// @dev Run the entire behavior suite against the basic contract, V1 proxy and V2 proxy.
abstract contract TripFundBehaviorTest is Test {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal organizer = makeAddr("organizer");
    address internal outsider = makeAddr("outsider");
    address internal adminOwner = makeAddr("adminOwner");
    uint256 internal constant GOAL = 100 ether;
    uint256 internal constant INITIAL_BALANCE = 1_000 ether;
    uint256 internal deadline;
    MockTripToken internal token;
    TripFundCore internal fund;

    event Contributed(address indexed contributor, uint256 amount);
    event Refunded(address indexed contributor, uint256 amount);
    event Withdrawn(address indexed organizer, uint256 amount);

    function _createFund(IERC20 token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
        virtual
        returns (TripFundCore);

    function setUp() public virtual {
        vm.warp(1_000_000);
        deadline = block.timestamp + 7 days;
        token = new MockTripToken();
        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);
        fund = _createFund(token, organizer, GOAL, deadline);
    }

    function _contribute(address user, uint256 amount) internal {
        vm.startPrank(user);
        token.approve(address(fund), amount);
        fund.contribute(amount);
        vm.stopPrank();
    }

    function _expectSafeTransferFailure(MockTripToken badToken) internal {
        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(badToken))
        );
    }

    function testParametersAndInitialState() public view {
        assertEq(address(fund.token()), address(token));
        assertEq(fund.organizer(), organizer);
        assertEq(fund.goal(), GOAL);
        assertEq(fund.deadline(), deadline);
        assertEq(fund.totalRaised(), 0);
        assertEq(fund.contributions(alice), 0);
        assertFalse(fund.withdrawn());
        assertEq(token.decimals(), 18);
    }

    function testTwoParticipantsAndRepeatedContributions() public {
        _contribute(alice, 20 ether);
        _contribute(bob, 30 ether);
        _contribute(alice, 15 ether);
        assertEq(fund.contributions(alice), 35 ether);
        assertEq(fund.contributions(bob), 30 ether);
        assertEq(fund.totalRaised(), 65 ether);
        assertEq(token.balanceOf(address(fund)), 65 ether);
        assertEq(token.balanceOf(alice), 965 ether);
        assertEq(token.balanceOf(bob), 970 ether);
    }

    function testContributionEvent() public {
        vm.startPrank(alice);
        token.approve(address(fund), 10 ether);
        vm.expectEmit(true, false, false, true, address(fund));
        emit Contributed(alice, 10 ether);
        fund.contribute(10 ether);
        vm.stopPrank();
    }

    function testZeroContributionRevertsWithoutChanges() public {
        vm.prank(alice);
        vm.expectRevert(TripFundCore.ZeroAmount.selector);
        fund.contribute(0);
        assertEq(fund.totalRaised(), 0);
        assertEq(fund.contributions(alice), 0);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(fund)), 0);
    }

    function testInsufficientAllowanceRevertsWithoutChanges() public {
        _contribute(alice, 5 ether);
        vm.startPrank(alice);
        token.approve(address(fund), 9 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(fund), 9 ether, 10 ether
            )
        );
        fund.contribute(10 ether);
        vm.stopPrank();
        assertEq(fund.totalRaised(), 5 ether);
        assertEq(fund.contributions(alice), 5 ether);
        assertEq(token.balanceOf(alice), 995 ether);
        assertEq(token.balanceOf(address(fund)), 5 ether);
        assertEq(token.allowance(alice, address(fund)), 9 ether);
    }

    function testMissingApprovalRevertsWithoutChanges() public {
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(fund), 0, 1 ether
            )
        );
        fund.contribute(1 ether);
        assertEq(fund.totalRaised(), 0);
        assertEq(fund.contributions(bob), 0);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(fund)), 0);
    }

    function testInsufficientBalanceRevertsAndRestoresAllowance() public {
        vm.startPrank(alice);
        token.approve(address(fund), INITIAL_BALANCE + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                alice,
                INITIAL_BALANCE,
                INITIAL_BALANCE + 1
            )
        );
        fund.contribute(INITIAL_BALANCE + 1);
        vm.stopPrank();
        assertEq(fund.totalRaised(), 0);
        assertEq(fund.contributions(alice), 0);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(token.allowance(alice, address(fund)), INITIAL_BALANCE + 1);
    }

    function testContributionOneSecondBeforeDeadline() public {
        vm.warp(deadline - 1);
        _contribute(alice, 1 ether);
        assertEq(fund.totalRaised(), 1 ether);
        assertEq(token.balanceOf(address(fund)), 1 ether);
    }

    function testContributionExactlyAtDeadlineReverts() public {
        vm.startPrank(alice);
        token.approve(address(fund), 1 ether);
        vm.warp(deadline);
        vm.expectRevert(TripFundCore.FundClosed.selector);
        fund.contribute(1 ether);
        vm.stopPrank();
        assertEq(fund.totalRaised(), 0);
        assertEq(fund.contributions(alice), 0);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(token.allowance(alice, address(fund)), 1 ether);
    }

    function testContributionAfterDeadlineReverts() public {
        vm.warp(deadline + 1);
        vm.prank(alice);
        vm.expectRevert(TripFundCore.FundClosed.selector);
        fund.contribute(1 ether);
    }

    function testPayoutsBeforeDeadlineRevertOnFailure() public {
        _contribute(alice, 10 ether);
        vm.warp(deadline - 1);
        vm.prank(organizer);
        vm.expectRevert(TripFundCore.DeadlineNotReached.selector);
        fund.withdraw();
        vm.prank(alice);
        vm.expectRevert(TripFundCore.DeadlineNotReached.selector);
        fund.refund();
        assertEq(fund.contributions(alice), 10 ether);
        assertFalse(fund.withdrawn());
        assertEq(token.balanceOf(address(fund)), 10 ether);
    }

    function testPayoutsBeforeDeadlineRevertEvenWhenGoalReached() public {
        _contribute(alice, GOAL);
        vm.warp(deadline - 1);
        vm.prank(organizer);
        vm.expectRevert(TripFundCore.DeadlineNotReached.selector);
        fund.withdraw();
        vm.prank(alice);
        vm.expectRevert(TripFundCore.DeadlineNotReached.selector);
        fund.refund();
        assertEq(fund.totalRaised(), GOAL);
        assertFalse(fund.withdrawn());
        assertEq(token.balanceOf(organizer), 0);
        assertEq(token.balanceOf(address(fund)), GOAL);
    }

    function testWithdrawExactlyGoalAtDeadlineAndEvent() public {
        _contribute(alice, 40 ether);
        _contribute(bob, 60 ether);
        vm.warp(deadline);
        vm.prank(organizer);
        vm.expectEmit(true, false, false, true, address(fund));
        emit Withdrawn(organizer, GOAL);
        fund.withdraw();
        assertTrue(fund.withdrawn());
        assertEq(token.balanceOf(organizer), GOAL);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(token.balanceOf(alice), 960 ether);
        assertEq(token.balanceOf(bob), 940 ether);
        assertEq(fund.totalRaised(), GOAL);
        assertEq(fund.contributions(alice), 40 ether);
        assertEq(fund.contributions(bob), 60 ether);
    }

    function testWithdrawAboveGoalPaysWholeAccountedAmount() public {
        _contribute(alice, 80 ether);
        _contribute(bob, 50 ether);
        vm.warp(deadline + 1);
        vm.prank(organizer);
        fund.withdraw();
        assertEq(token.balanceOf(organizer), 130 ether);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(fund.totalRaised(), 130 ether);
    }

    function testOnlyOrganizerCanWithdraw() public {
        _contribute(alice, GOAL);
        vm.warp(deadline);
        vm.prank(outsider);
        vm.expectRevert(TripFundCore.NotOrganizer.selector);
        fund.withdraw();
        assertFalse(fund.withdrawn());
        assertEq(token.balanceOf(organizer), 0);
        assertEq(token.balanceOf(address(fund)), GOAL);
    }

    function testWithdrawalCannotRepeat() public {
        _contribute(alice, GOAL);
        vm.warp(deadline);
        vm.startPrank(organizer);
        fund.withdraw();
        vm.expectRevert(TripFundCore.AlreadyWithdrawn.selector);
        fund.withdraw();
        vm.stopPrank();
        assertEq(token.balanceOf(organizer), GOAL);
        assertEq(fund.totalRaised(), GOAL);
    }

    function testRefundForbiddenOnSuccessBeforeAndAfterWithdrawal() public {
        _contribute(alice, GOAL);
        vm.warp(deadline);
        vm.prank(alice);
        vm.expectRevert(TripFundCore.GoalReached.selector);
        fund.refund();
        vm.prank(organizer);
        fund.withdraw();
        vm.prank(alice);
        vm.expectRevert(TripFundCore.GoalReached.selector);
        fund.refund();
        assertEq(fund.contributions(alice), GOAL);
        assertEq(token.balanceOf(alice), 900 ether);
    }

    function testIndependentFullRefundsAndEvent() public {
        _contribute(alice, 20 ether);
        _contribute(bob, 30 ether);
        _contribute(alice, 10 ether);
        vm.warp(deadline);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(fund));
        emit Refunded(alice, 30 ether);
        fund.refund();
        assertEq(fund.contributions(alice), 0);
        assertEq(fund.contributions(bob), 30 ether);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.balanceOf(bob), 970 ether);
        assertEq(token.balanceOf(address(fund)), 30 ether);
        assertEq(fund.totalRaised(), 60 ether);
        vm.prank(bob);
        fund.refund();
        assertEq(fund.contributions(bob), 0);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(fund.totalRaised(), 60 ether);
        assertFalse(fund.withdrawn());
    }

    function testRefundWithoutContributionAndRepeatedRefundRevert() public {
        _contribute(alice, 10 ether);
        vm.warp(deadline);
        vm.prank(outsider);
        vm.expectRevert(TripFundCore.NoContribution.selector);
        fund.refund();
        vm.startPrank(alice);
        fund.refund();
        vm.expectRevert(TripFundCore.NoContribution.selector);
        fund.refund();
        vm.stopPrank();
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(fund.totalRaised(), 10 ether);
    }

    function testWithdrawalOnFailureReverts() public {
        _contribute(alice, GOAL - 1);
        vm.warp(deadline);
        vm.prank(organizer);
        vm.expectRevert(TripFundCore.GoalNotReached.selector);
        fund.withdraw();
        assertFalse(fund.withdrawn());
        assertEq(token.balanceOf(address(fund)), GOAL - 1);
        assertEq(token.balanceOf(organizer), 0);
    }

    function testEmptyFundHasNoPayouts() public {
        vm.warp(deadline);
        vm.prank(organizer);
        vm.expectRevert(TripFundCore.GoalNotReached.selector);
        fund.withdraw();
        vm.prank(alice);
        vm.expectRevert(TripFundCore.NoContribution.selector);
        fund.refund();
    }

    function testDirectTransfersStayAfterWithdrawal() public {
        _contribute(alice, GOAL);
        vm.prank(bob);
        assertTrue(token.transfer(address(fund), 7 ether));
        assertEq(fund.totalRaised(), GOAL);
        assertEq(fund.contributions(bob), 0);
        vm.warp(deadline);
        vm.prank(organizer);
        fund.withdraw();
        assertEq(token.balanceOf(organizer), GOAL);
        assertEq(token.balanceOf(address(fund)), 7 ether);
        assertEq(fund.totalRaised(), GOAL);
    }

    function testDirectTransfersStayAfterAllRefundsAndCannotReachGoal() public {
        _contribute(alice, 20 ether);
        _contribute(bob, 30 ether);
        vm.prank(bob);
        assertTrue(token.transfer(address(fund), GOAL));
        assertEq(fund.totalRaised(), 50 ether);
        assertEq(fund.contributions(bob), 30 ether);
        vm.warp(deadline);
        vm.prank(organizer);
        vm.expectRevert(TripFundCore.GoalNotReached.selector);
        fund.withdraw();
        vm.prank(bob);
        fund.refund();
        vm.prank(alice);
        fund.refund();
        assertEq(token.balanceOf(address(fund)), GOAL);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE - GOAL);
        assertEq(fund.totalRaised(), 50 ether);
    }

    function testFalseTransferFromRevertsAccounting() public {
        FailingTripToken badToken = new FailingTripToken();
        fund = _createFund(badToken, organizer, GOAL, deadline);
        badToken.mint(alice, GOAL);
        badToken.setFailures(false, true);
        vm.startPrank(alice);
        badToken.approve(address(fund), GOAL);
        _expectSafeTransferFailure(badToken);
        fund.contribute(GOAL);
        vm.stopPrank();
        assertEq(fund.contributions(alice), 0);
        assertEq(fund.totalRaised(), 0);
        assertEq(badToken.balanceOf(alice), GOAL);
        assertEq(badToken.balanceOf(address(fund)), 0);
        assertEq(badToken.allowance(alice, address(fund)), GOAL);
    }

    function testWithdrawalTransferFailureRestoresFlagAndCanBeRetried() public {
        FailingTripToken badToken = new FailingTripToken();
        fund = _createFund(badToken, organizer, GOAL, deadline);
        token = badToken;
        badToken.mint(alice, GOAL);
        _contribute(alice, GOAL);
        badToken.setFailures(true, false);
        vm.warp(deadline);
        vm.prank(organizer);
        _expectSafeTransferFailure(badToken);
        fund.withdraw();
        assertFalse(fund.withdrawn());
        assertEq(fund.totalRaised(), GOAL);
        assertEq(fund.contributions(alice), GOAL);
        assertEq(badToken.balanceOf(organizer), 0);
        assertEq(badToken.balanceOf(address(fund)), GOAL);
        badToken.setFailures(false, false);
        vm.prank(organizer);
        fund.withdraw();
        assertTrue(fund.withdrawn());
        assertEq(badToken.balanceOf(organizer), GOAL);
    }

    function testRefundTransferFailureRestoresContributionAndCanBeRetried() public {
        FailingTripToken badToken = new FailingTripToken();
        fund = _createFund(badToken, organizer, GOAL, deadline);
        token = badToken;
        badToken.mint(alice, 10 ether);
        _contribute(alice, 10 ether);
        badToken.setFailures(true, false);
        vm.warp(deadline);
        vm.prank(alice);
        _expectSafeTransferFailure(badToken);
        fund.refund();
        assertEq(fund.contributions(alice), 10 ether);
        assertEq(fund.totalRaised(), 10 ether);
        assertEq(badToken.balanceOf(alice), 0);
        assertEq(badToken.balanceOf(address(fund)), 10 ether);
        badToken.setFailures(false, false);
        vm.prank(alice);
        fund.refund();
        assertEq(fund.contributions(alice), 0);
        assertEq(badToken.balanceOf(alice), 10 ether);
        assertEq(fund.totalRaised(), 10 ether);
    }

    function testFuzzRepeatedContributions(uint256 first, uint256 second, uint256 third) public {
        first = bound(first, 1, 400 ether);
        second = bound(second, 1, 400 ether);
        third = bound(third, 1, 400 ether);
        _contribute(alice, first);
        _contribute(bob, second);
        _contribute(alice, third);
        assertEq(fund.contributions(alice), first + third);
        assertEq(fund.contributions(bob), second);
        assertEq(fund.totalRaised(), first + second + third);
        assertEq(token.balanceOf(address(fund)), first + second + third);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - first - third);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE - second);
    }

    function testFuzzFailedFundRefunds(uint256 aliceAmount, uint256 bobAmount) public {
        aliceAmount = bound(aliceAmount, 1, 40 ether);
        bobAmount = bound(bobAmount, 1, 40 ether);
        _contribute(alice, aliceAmount);
        _contribute(bob, bobAmount);
        vm.warp(deadline);
        vm.prank(bob);
        fund.refund();
        vm.prank(alice);
        fund.refund();
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(fund.totalRaised(), aliceAmount + bobAmount);
        assertEq(fund.contributions(alice), 0);
        assertEq(fund.contributions(bob), 0);
    }

    function testFuzzSuccessfulPayoutExcludesDonations(uint256 amount, uint256 donation) public {
        amount = bound(amount, GOAL, INITIAL_BALANCE);
        donation = bound(donation, 0, INITIAL_BALANCE);
        _contribute(alice, amount);
        vm.prank(bob);
        assertTrue(token.transfer(address(fund), donation));
        vm.warp(deadline);
        vm.prank(organizer);
        fund.withdraw();
        assertEq(token.balanceOf(organizer), amount);
        assertEq(token.balanceOf(address(fund)), donation);
        assertEq(fund.totalRaised(), amount);
        assertTrue(fund.withdrawn());
    }
}

contract TripFundTest is TripFundBehaviorTest {
    function _createFund(IERC20 token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
        override
        returns (TripFundCore)
    {
        return new TripFund(token_, organizer_, goal_, deadline_);
    }

    function testConstructorRejectsZeroToken() public {
        vm.expectRevert(TripFundCore.ZeroAddress.selector);
        new TripFund(IERC20(address(0)), organizer, GOAL, deadline);
    }

    function testConstructorRejectsZeroOrganizer() public {
        vm.expectRevert(TripFundCore.ZeroAddress.selector);
        new TripFund(token, address(0), GOAL, deadline);
    }

    function testConstructorRejectsZeroGoal() public {
        vm.expectRevert(TripFundCore.ZeroGoal.selector);
        new TripFund(token, organizer, 0, deadline);
    }

    function testConstructorRejectsPresentAndPastDeadlines() public {
        vm.expectRevert(TripFundCore.InvalidDeadline.selector);
        new TripFund(token, organizer, GOAL, block.timestamp);
        vm.expectRevert(TripFundCore.InvalidDeadline.selector);
        new TripFund(token, organizer, GOAL, block.timestamp - 1);
    }
}

contract TripFundProxyV1BehaviorTest is TripFundBehaviorTest {
    function _createFund(IERC20 token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
        override
        returns (TripFundCore)
    {
        TripFundV1 implementation = new TripFundV1();
        return TripFundCore(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    adminOwner,
                    abi.encodeCall(TripFundV1.initialize, (token_, organizer_, goal_, deadline_))
                )
            )
        );
    }
}

contract TripFundProxyV2BehaviorTest is TripFundBehaviorTest {
    bytes32 internal constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);

    function _createFund(IERC20 token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
        override
        returns (TripFundCore)
    {
        TripFundV1 implementation = new TripFundV1();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            adminOwner,
            abi.encodeCall(TripFundV1.initialize, (token_, organizer_, goal_, deadline_))
        );
        ProxyAdmin admin =
            ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), ADMIN_SLOT)))));
        TripFundV2 next = new TripFundV2();
        vm.prank(adminOwner);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(next), "");
        return TripFundCore(address(proxy));
    }
}
