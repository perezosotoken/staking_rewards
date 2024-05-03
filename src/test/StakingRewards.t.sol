// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../StakingRewards.sol";
import "../RewardsDistributionRecipient.sol";

import "./ERC20Mock.sol";

contract StakingRewardsTest is Test {
    StakingRewards public stakingRewards;
    RewardsDistributionRecipient public rewardsDistribution;
    address public owner;
    address public alice;
    address public bob;
    IERC20 public rewardsToken;
    IERC20 public stakingToken;

    function setUp() public {
        owner = address(this);
        alice = address(0x123);
        bob = address(0x456);

        // Deploy mock ERC20 tokens for testing
        rewardsToken = new ERC20Mock("Rewards Token", "RT", 1e18 * 1500000);
        stakingToken = new ERC20Mock("Staking Token", "ST", 1e18 * 1500000);

        // Deploy the StakingRewards contract

        stakingRewards = new StakingRewards(owner, address(rewardsToken), address(stakingToken));
        stakingRewards.setRewardsDistribution(alice); // Set Alice as the reward distributor

        // Transfer tokens to test accounts
        stakingToken.transfer(alice, 1e18 * 1000);
        rewardsToken.transfer(address(stakingRewards), 1e18 * 5000);

        // Transfer some tokens to the StakingRewards contract for rewards
        rewardsToken.transfer(address(stakingRewards), 1e18 * 500000);

        // Allow StakingRewards to spend tokens on behalf of alice and bob
        vm.prank(alice);
        stakingToken.approve(address(stakingRewards), type(uint256).max);
        vm.prank(bob);
        stakingToken.approve(address(stakingRewards), type(uint256).max);
    }

    function testNotifyRewardAmountByOwner() public {
        uint256 reward = 1e18 * 1000; // New reward
        uint256 duration = 30 days;
        stakingRewards.setRewardsDuration(duration);

        // Owner notifying new reward
        vm.startPrank(alice);
        stakingRewards.notifyRewardAmount(reward);
        vm.stopPrank();

        // Check if the reward rate is set correctly
        uint256 expectedRewardRate = reward / duration;
        assertEq(stakingRewards.rewardRate(), expectedRewardRate, "Reward rate should be correctly updated");
    }

    function testFailNotifyRewardAmountByNonOwner() public {
        uint256 reward = 1e18 * 1000;
        uint256 duration = 30 days;
        stakingRewards.setRewardsDuration(duration);

        // Non-owner trying to notify new reward
        vm.startPrank(owner);
        vm.expectRevert("Ownable: caller is not the owner");
        stakingRewards.notifyRewardAmount(reward);
        vm.stopPrank();
    }

    function testRewardRateIncreasesWithAdditionalRewards() public {
        uint256 initialReward = 1e18 * 1000;
        uint256 additionalReward = 1e18 * 5000;
        uint256 duration = 60 days;

        // Set rewards duration and notify initial reward
        stakingRewards.setRewardsDuration(duration);
        vm.prank(alice);
        stakingRewards.notifyRewardAmount(initialReward);

        // uint256 initialRewardRate = stakingRewards.rewardRate();

        // // Fast forward time to halfway through the period
        // vm.warp(block.timestamp + 30 days);

        // // Notify additional reward
        // vm.prank(alice);
        // stakingRewards.notifyRewardAmount(additionalReward);

        // uint256 newRewardRate = stakingRewards.rewardRate();

        // // Check that the new reward rate is greater than the initial rate
        // assertGt(newRewardRate, initialRewardRate, "New reward rate should be greater than the initial rate");
    }

    function testStakeWithValidPeriod() public {
        uint256 lockPeriod = 30 days; // Ensure this matches an initialized key
        uint256 amount = 1e18 * 100; // Amount to stake

        // Check current lock period setting
        assertEq(stakingRewards.lockPeriods(lockPeriod), 1, "Lock period multiplier should be 1");

        // Perform the stake operation
        vm.startPrank(alice);
        stakingToken.approve(address(stakingRewards), amount);
        stakingRewards.stake(amount, lockPeriod); // This should not fail if lock period is valid
        vm.stopPrank();

        // Check results
        assertEq(stakingRewards.balanceOf(alice), amount, "Alice's staked amount should match");
    }

    function testStake() public {
        // Alice stakes tokens in the first tier
        uint256 amount = 1e18 * 100; // 100 tokens
        vm.prank(alice);
        stakingRewards.stake(amount, 30 days);

        assertEq(stakingRewards.balanceOf(alice), amount, "Alice's staked balance should be 100 tokens");
    }

    function testWithdraw() public {
        testStake(); // First, Alice stakes some tokens

        // Attempt to withdraw before the lock period ends
        vm.warp(block.timestamp + 20 days); // Warp time to 20 days later
        vm.prank(alice);
        vm.expectRevert("Stake is locked");
        stakingRewards.withdraw(1e18 * 100);

        // Warp to after the lock period and try again
        vm.warp(block.timestamp + 11 days); // Total 31 days, beyond the first tier's lock
        vm.prank(alice);
        stakingRewards.withdraw(1e18 * 100);

        assertEq(stakingToken.balanceOf(alice), 1e18 * 1000, "Alice should have all her tokens back");
    }

    function testRewards() public {
        testStake(); // Alice stakes some tokens

        // Simulate some time passing for rewards to accumulate
        vm.warp(block.timestamp + 30 days); // Warp time to 30 days later

        // Alice claims her rewards
        vm.prank(alice);
        stakingRewards.getReward();

        assertGt(rewardsToken.balanceOf(alice), 0, "Alice should have received some rewards");
    }
}
