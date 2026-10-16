// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TripFundCore} from "../src/TripFundCore.sol";
import {TripFundV1} from "../src/TripFundV1.sol";
import {TripFundV2} from "../src/TripFundV2.sol";
import {MockTripToken} from "../src/MockTripToken.sol";

contract TripFundUpgradeTest is Test {
    bytes32 private constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    bytes32 private constant IMPLEMENTATION_SLOT =
        bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    address private adminOwner = makeAddr("adminOwner");
    address private organizer = makeAddr("organizer");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private friend = makeAddr("friend");
    uint256 private constant GOAL = 100 ether;
    uint256 private deadline;
    MockTripToken private token;
    TripFundV1 private implementationV1;
    TripFundV2 private implementationV2;
    TransparentUpgradeableProxy private proxy;
    ProxyAdmin private admin;
    TripFundV1 private fundV1;

    event ContributedFor(address indexed payer, address indexed beneficiary, uint256 amount);

    function setUp() public {
        vm.warp(1_000_000);
        deadline = block.timestamp + 7 days;
        token = new MockTripToken();
        token.mint(alice, 1_000 ether);
        token.mint(bob, 1_000 ether);
        implementationV1 = new TripFundV1();
        implementationV2 = new TripFundV2();
        proxy = new TransparentUpgradeableProxy(
            address(implementationV1),
            adminOwner,
            abi.encodeCall(TripFundV1.initialize, (token, organizer, GOAL, deadline))
        );
        admin = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), ADMIN_SLOT)))));
        fundV1 = TripFundV1(address(proxy));
    }

    function _upgrade() private returns (TripFundV2) {
        vm.prank(adminOwner);
        admin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)), address(implementationV2), ""
        );
        return TripFundV2(address(proxy));
    }

    function _contributeV1(address payer, uint256 amount) private {
        vm.startPrank(payer);
        token.approve(address(proxy), amount);
        fundV1.contribute(amount);
        vm.stopPrank();
    }

    function testV1ProxyIsInitializedAtomicallyAndAdminHasOwner() public view {
        assertEq(admin.owner(), adminOwner);
        assertEq(address(fundV1.token()), address(token));
        assertEq(fundV1.organizer(), organizer);
        assertEq(fundV1.goal(), GOAL);
        assertEq(fundV1.deadline(), deadline);
        assertEq(
            vm.load(address(proxy), IMPLEMENTATION_SLOT),
            bytes32(uint256(uint160(address(implementationV1))))
        );
    }

    function testV1ContributionUpgradeAndContributionForFriendThenRefunds() public {
        address originalAddress = address(fundV1);
        _contributeV1(alice, 20 ether);
        _contributeV1(bob, 5 ether);
        _contributeV1(alice, 10 ether);
        vm.prank(bob);
        assertTrue(token.transfer(address(proxy), 7 ether));
        vm.warp(deadline - 1 days);

        TripFundV2 fundV2 = _upgrade();
        assertEq(address(fundV2), originalAddress);
        assertEq(address(fundV2.token()), address(token));
        assertEq(fundV2.organizer(), organizer);
        assertEq(fundV2.goal(), GOAL);
        assertEq(fundV2.deadline(), deadline);
        assertEq(fundV2.contributions(alice), 30 ether);
        assertEq(fundV2.contributions(bob), 5 ether);
        assertEq(fundV2.totalRaised(), 35 ether);
        assertEq(token.balanceOf(address(proxy)), 42 ether);
        assertFalse(fundV2.withdrawn());
        assertEq(
            vm.load(address(proxy), IMPLEMENTATION_SLOT),
            bytes32(uint256(uint160(address(implementationV2))))
        );

        vm.startPrank(alice);
        token.approve(address(proxy), 30 ether);
        vm.expectEmit(true, true, false, true, address(proxy));
        emit ContributedFor(alice, friend, 15 ether);
        fundV2.contributeFor(friend, 15 ether);
        fundV2.contributeFor(friend, 10 ether);
        fundV2.contribute(5 ether);
        vm.stopPrank();

        assertEq(fundV2.contributions(friend), 25 ether);
        assertEq(fundV2.contributions(alice), 35 ether);
        assertEq(fundV2.totalRaised(), 65 ether);
        assertEq(token.balanceOf(alice), 940 ether);
        assertEq(token.balanceOf(friend), 0);
        assertEq(token.balanceOf(address(proxy)), 72 ether);

        vm.warp(deadline);
        vm.prank(friend);
        fundV2.refund();
        assertEq(token.balanceOf(friend), 25 ether);
        assertEq(fundV2.contributions(friend), 0);
        assertEq(token.balanceOf(alice), 940 ether);
        vm.prank(alice);
        fundV2.refund();
        vm.prank(bob);
        fundV2.refund();
        assertEq(token.balanceOf(alice), 975 ether);
        assertEq(token.balanceOf(bob), 993 ether);
        assertEq(token.balanceOf(address(proxy)), 7 ether);
        assertEq(fundV2.totalRaised(), 65 ether);
        vm.prank(friend);
        vm.expectRevert(TripFundCore.NoContribution.selector);
        fundV2.refund();
    }

    function testContributeForDoesNotGivePayerRefundRights() public {
        TripFundV2 fundV2 = _upgrade();
        vm.startPrank(alice);
        token.approve(address(proxy), 10 ether);
        fundV2.contributeFor(friend, 10 ether);
        vm.stopPrank();
        vm.warp(deadline);
        vm.prank(alice);
        vm.expectRevert(TripFundCore.NoContribution.selector);
        fundV2.refund();
        vm.prank(friend);
        fundV2.refund();
        assertEq(token.balanceOf(friend), 10 ether);
        assertEq(token.balanceOf(alice), 990 ether);
        assertEq(token.balanceOf(address(proxy)), 0);
    }

    function testContributeForSumsWithExistingBeneficiaryContribution() public {
        _contributeV1(bob, 10 ether);
        TripFundV2 fundV2 = _upgrade();
        vm.startPrank(alice);
        token.approve(address(proxy), 12 ether);
        fundV2.contributeFor(bob, 7 ether);
        fundV2.contributeFor(bob, 5 ether);
        vm.stopPrank();
        assertEq(fundV2.contributions(bob), 22 ether);
        assertEq(fundV2.contributions(alice), 0);
        assertEq(fundV2.totalRaised(), 22 ether);
        vm.warp(deadline);
        vm.prank(bob);
        fundV2.refund();
        assertEq(token.balanceOf(bob), 1_012 ether);
        assertEq(token.balanceOf(alice), 988 ether);
    }

    function testContributeForSelfIsAllowed() public {
        TripFundV2 fundV2 = _upgrade();
        vm.startPrank(alice);
        token.approve(address(proxy), 10 ether);
        fundV2.contributeFor(alice, 10 ether);
        vm.stopPrank();
        assertEq(fundV2.contributions(alice), 10 ether);
        assertEq(fundV2.totalRaised(), 10 ether);
    }

    function testContributeForRejectsZeroBeneficiaryAndAmount() public {
        TripFundV2 fundV2 = _upgrade();
        vm.startPrank(alice);
        token.approve(address(proxy), 10 ether);
        vm.expectRevert(TripFundCore.ZeroAddress.selector);
        fundV2.contributeFor(address(0), 10 ether);
        vm.expectRevert(TripFundCore.ZeroAmount.selector);
        fundV2.contributeFor(friend, 0);
        vm.stopPrank();
        assertEq(fundV2.totalRaised(), 0);
        assertEq(fundV2.contributions(friend), 0);
        assertEq(fundV2.contributions(address(0)), 0);
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(address(proxy)), 0);
        assertEq(token.allowance(alice, address(proxy)), 10 ether);
    }

    function testContributeForUsesPayersAllowanceAndBalance() public {
        TripFundV2 fundV2 = _upgrade();
        vm.prank(friend);
        token.approve(address(proxy), type(uint256).max);
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(proxy), 0, 10 ether
            )
        );
        fundV2.contributeFor(friend, 10 ether);
        token.approve(address(proxy), 1_001 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, alice, 1_000 ether, 1_001 ether
            )
        );
        fundV2.contributeFor(friend, 1_001 ether);
        vm.stopPrank();
        assertEq(fundV2.totalRaised(), 0);
        assertEq(fundV2.contributions(friend), 0);
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(address(proxy)), 0);
        assertEq(token.allowance(alice, address(proxy)), 1_001 ether);
    }

    function testContributeForDeadlineBoundary() public {
        TripFundV2 fundV2 = _upgrade();
        vm.startPrank(alice);
        token.approve(address(proxy), 20 ether);
        vm.warp(deadline - 1);
        fundV2.contributeFor(friend, 10 ether);
        vm.warp(deadline);
        vm.expectRevert(TripFundCore.FundClosed.selector);
        fundV2.contributeFor(friend, 10 ether);
        vm.stopPrank();
        assertEq(fundV2.contributions(friend), 10 ether);
        assertEq(fundV2.totalRaised(), 10 ether);
        assertEq(token.balanceOf(address(proxy)), 10 ether);
        assertEq(token.allowance(alice, address(proxy)), 10 ether);
    }

    function testContributeForReachesGoalAndOnlyOrganizerWithdraws() public {
        TripFundV2 fundV2 = _upgrade();
        vm.startPrank(alice);
        token.approve(address(proxy), GOAL);
        fundV2.contributeFor(friend, GOAL);
        vm.stopPrank();
        vm.warp(deadline);
        vm.prank(friend);
        vm.expectRevert(TripFundCore.GoalReached.selector);
        fundV2.refund();
        vm.prank(friend);
        vm.expectRevert(TripFundCore.NotOrganizer.selector);
        fundV2.withdraw();
        vm.prank(organizer);
        fundV2.withdraw();
        assertEq(token.balanceOf(organizer), GOAL);
        assertEq(fundV2.totalRaised(), GOAL);
    }

    function testOutsiderAndOrganizerCannotUpgrade() public {
        for (uint256 i; i < 2; ++i) {
            address caller = i == 0 ? alice : organizer;
            vm.prank(caller);
            vm.expectRevert(
                abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller)
            );
            admin.upgradeAndCall(
                ITransparentUpgradeableProxy(address(proxy)), address(implementationV2), ""
            );
        }
        assertEq(
            vm.load(address(proxy), IMPLEMENTATION_SLOT),
            bytes32(uint256(uint160(address(implementationV1))))
        );
    }

    function testDirectProxyUpgradeByOwnerIsForbidden() public {
        // The ProxyAdmin contract, rather than its owner EOA, is the proxy's admin.
        vm.prank(adminOwner);
        vm.expectRevert();
        ITransparentUpgradeableProxy(address(proxy)).upgradeToAndCall(address(implementationV2), "");
        assertEq(
            vm.load(address(proxy), IMPLEMENTATION_SLOT),
            bytes32(uint256(uint160(address(implementationV1))))
        );
    }

    function testCannotReinitializeProxyInV1OrV2() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fundV1.initialize(token, alice, 1, deadline + 1);
        TripFundV2 fundV2 = _upgrade();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fundV2.initialize(token, alice, 1, deadline + 1);
        assertEq(fundV2.organizer(), organizer);
        assertEq(fundV2.goal(), GOAL);
        assertEq(fundV2.deadline(), deadline);
    }

    function testCannotInitializeEitherImplementationDirectly() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementationV1.initialize(token, organizer, GOAL, deadline);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementationV2.initialize(token, organizer, GOAL, deadline);
    }

    function testProxyInitializationRejectsInvalidParameters() public {
        vm.expectRevert(TripFundCore.ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(implementationV1),
            adminOwner,
            abi.encodeCall(TripFundV1.initialize, (IERC20(address(0)), organizer, GOAL, deadline))
        );
        vm.expectRevert(TripFundCore.ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(implementationV1),
            adminOwner,
            abi.encodeCall(TripFundV1.initialize, (token, address(0), GOAL, deadline))
        );
        vm.expectRevert(TripFundCore.ZeroGoal.selector);
        new TransparentUpgradeableProxy(
            address(implementationV1),
            adminOwner,
            abi.encodeCall(TripFundV1.initialize, (token, organizer, 0, deadline))
        );
        vm.expectRevert(TripFundCore.InvalidDeadline.selector);
        new TransparentUpgradeableProxy(
            address(implementationV1),
            adminOwner,
            abi.encodeCall(TripFundV1.initialize, (token, organizer, GOAL, block.timestamp))
        );
        vm.expectRevert(TripFundCore.InvalidDeadline.selector);
        new TransparentUpgradeableProxy(
            address(implementationV1),
            adminOwner,
            abi.encodeCall(TripFundV1.initialize, (token, organizer, GOAL, block.timestamp - 1))
        );
    }
}
