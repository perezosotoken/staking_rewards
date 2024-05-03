// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../StakingRewards.sol";
import "../RewardsDistributionRecipient.sol";
import "./ERC20Mock.sol";

contract StakingRewardsCalculations is Test {
    StakingRewards public stakingRewards;
    RewardsDistributionRecipient public rewardsDistribution;

    address public owner;
    address public alice; // Stakeholder
    IERC20 public rewardsToken;
    IERC20 public stakingToken;

    function setUp() public {
        owner = address(this); // Test contract is the owner
        alice = address(0x123);

        // Deploy mock ERC20 tokens for testing
        rewardsToken = new ERC20Mock("Rewards Token", "RT", 1e18 * 10000);
        stakingToken = new ERC20Mock("Staking Token", "ST", 1e18 * 10000);

        // Deploy the StakingRewards contract
        stakingRewards = new StakingRewards(owner, address(rewardsToken), address(stakingToken));

        stakingRewards.setRewardsDistribution(owner); // Set test contract as the reward distributor

        // Set rewards duration
        stakingRewards.setRewardsDuration(30 days);

        // Prepare tokens and allowances
        stakingToken.transfer(alice, 1e18 * 100);
        vm.startPrank(alice);
        stakingToken.approve(address(stakingRewards), 1e18 * 100);
        vm.stopPrank();

        // Stake tokens
        vm.startPrank(alice);
        stakingRewards.stake(1e18 * 100, 30 days); // Assume tier 0 is valid
        vm.stopPrank();

        // Set a reward amount
        rewardsToken.transfer(address(stakingRewards), 1e18 * 1000);
        vm.prank(owner);
        stakingRewards.notifyRewardAmount(1e18 * 1000);
    }

    function testLockPeriodsInitialization() public {
        assertEq(stakingRewards.lockPeriods(30 days), 1, "30 days lock period should be set to 1x");
        assertEq(stakingRewards.lockPeriods(60 days), 2, "60 days lock period should be set to 2x");
        assertEq(stakingRewards.lockPeriods(90 days), 3, "90 days lock period should be set to 3x");
        assertEq(stakingRewards.lockPeriods(365 days), 6, "365 days lock period should be set to 6x");
    }

    function testGetRewardForDuration() public {
        // Assert that the reward for the duration is correctly calculated
        uint256 expectedReward = stakingRewards.rewardRate() * 30 days;
        assertEq(stakingRewards.getRewardForDuration(), expectedReward, "Reward for duration should match expected reward rate times duration");
    }

    function testRewardPerToken() public {
        // Get the reward per token calculation
        uint256 rPerToken = stakingRewards.rewardPerToken();

        // Assert non-zero reward per token (since time has advanced and tokens are staked)
        assertGt(rPerToken, 0, "Reward per token should be greater than zero");

        // Warp further into the future and check if reward per token increases
        vm.warp(block.timestamp + 10 days);
        uint256 newRPerToken = stakingRewards.rewardPerToken();
        assertGt(newRPerToken, rPerToken, "Reward per token should increase over time");
    }

}
