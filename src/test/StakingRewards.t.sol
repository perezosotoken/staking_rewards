// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../StakingRewards.sol";
import "../RewardsDistributionRecipient.sol";

import "./ERC20Mock.sol";

contract StakingRewardsTest is Test {
    StakingRewards public stakingRewards;
    address public owner;
    address public alice;
    address public bob;
    ERC20Mock public rewardsToken;
    ERC20Mock public stakingToken;

    function setUp() public {
        owner = address(this);
        alice = address(0x123);
        bob = address(0x456);

        rewardsToken = new ERC20Mock("Rewards Token", "RT", 1e18 * 1500000);
        stakingToken = new ERC20Mock("Staking Token", "ST", 1e18 * 1500000);

        stakingRewards = new StakingRewards(owner, address(rewardsToken), address(stakingToken));
        stakingRewards.setRewardsDistribution(owner); 
 
        stakingRewards.transferOwnership(alice); // Set Alice as the owner for rewards distribution

        // Distribute tokens and approvals
        stakingToken.transfer(alice, 1e18 * 1000);
        stakingToken.transfer(bob, 1e18 * 1000);
        rewardsToken.transfer(address(stakingRewards), 1e18 * 500000);
        stakingToken.approve(address(stakingRewards), type(uint256).max);

        vm.prank(alice);
        stakingToken.approve(address(stakingRewards), type(uint256).max);
        vm.stopPrank();

        vm.prank(bob);
        stakingToken.approve(address(stakingRewards), type(uint256).max);
        vm.stopPrank();
    }

    function testNotifyRewardAmountByOwner() public {
        uint256 reward = 1e18 * 1000;
        uint256 duration = 30 days;

        vm.prank(alice);
        stakingRewards.setRewardsDuration(duration);
        vm.stopPrank();

        vm.prank(owner);
        stakingRewards.notifyRewardAmount(reward);
        vm.stopPrank();

        uint256 expectedRewardRate = reward / duration;
        assertEq(stakingRewards.rewardRate(), expectedRewardRate, "Reward rate should be correctly updated");
    }

    function testFailNotifyRewardAmountByNonOwner() public {
        uint256 reward = 1e18 * 1000;
        uint256 duration = 30 days;
        stakingRewards.setRewardsDuration(duration);
        vm.prank(bob);
        vm.expectRevert("Ownable: caller is not the owner");
        stakingRewards.notifyRewardAmount(reward);
    }

    function testStakeWithValidPeriod() public {
        uint256 lockPeriod = 30 days;
        uint256 amount = 1e18 * 100;
        vm.prank(alice);
        stakingRewards.stake(amount, lockPeriod);
        assertEq(stakingRewards.balanceOf(alice), amount, "Alice's staked balance should be 100 tokens");
        // Retrieve the entire struct as a tuple for the first stake
        (uint256 stakedAmount,,) = stakingRewards.stakes(alice, 0);
        assertEq(stakedAmount, amount, "Stake amount should be correct");

    }


    function testMultipleStakes() public {
        uint256 amount = 1e18 * 100;
        uint256 lockPeriod1 = 30 days;
        uint256 lockPeriod2 = 90 days;
        vm.startPrank(alice);
        stakingRewards.stake(amount, lockPeriod1);
        stakingRewards.stake(amount * 2, lockPeriod2);
        vm.stopPrank();

        // Retrieve the entire struct as a tuple for the first stake
        (uint256 stakedAmount1, uint256 stakedLockPeriod1, uint256 stakedLockEnd1) = stakingRewards.stakes(alice, 0);
        assertEq(stakedAmount1, amount, "First stake amount should be correct");

        // Retrieve the entire struct as a tuple for the second stake
        (uint256 stakedAmount2, uint256 stakedLockPeriod2, uint256 stakedLockEnd2) = stakingRewards.stakes(alice, 1);
        assertEq(stakedAmount2, amount * 2, "Second stake amount should be correct");
    }


    // function testWithdraw() public {
    //     testStakeWithValidPeriod();
    //     uint256 amount = 1e18 * 100;
    //     uint256 aliceInitialBalance = 1000e18;
    //     vm.warp(block.timestamp + 31 days); // Move time to after both lock periods
    //     vm.startPrank(alice);
    //     stakingRewards.withdraw(0); // Withdraw the first stake
    //     assertEq(stakingToken.balanceOf(alice) , amount, "Alice should have received her staked tokens back");
    //     // stakingRewards.withdraw(0); // Withdraw the second stake (now at index 0)
    //     // assertEq(stakingToken.balanceOf(alice), amount * 2, "Alice should have received all her staked tokens back");
        

    //     vm.stopPrank();
 
    // }
   function testWithdraw() public {
        // First, Alice stakes some tokens
        uint256 amount = 1e18 * 100;
        uint256 aliceInitialBalance = stakingToken.balanceOf(alice);

        vm.prank(alice);
        stakingRewards.stake(amount, 30 days);

        // Attempt to withdraw before the lock period ends
        vm.warp(block.timestamp + 20 days); // Move time to before the lock period ends
        vm.prank(alice);
        vm.expectRevert("Stake is locked");
        stakingRewards.withdraw(0);

        // Warp to after the lock period and try to withdraw
        vm.warp(block.timestamp + 11 days); // Move time to after the lock period
        vm.prank(alice);
        stakingRewards.withdraw(0);

        uint256 aliceFinalBalance = stakingToken.balanceOf(alice);
        assertEq(aliceFinalBalance, aliceInitialBalance, "Alice should have all her staked tokens back after withdrawal");

        // Check if the staking balance reflects the withdrawal
        assertEq(stakingRewards.balanceOf(alice), 0, "Alice's staking balance should be zero after withdrawal");
    }

    function testWithdrawMultipleStakes() public {
        // Alice stakes twice
        uint256 amount1 = 1e18 * 100;
        uint256 amount2 = 1e18 * 200;

        uint256 aliceBalanceBeforeFirstStake = stakingToken.balanceOf(alice); 
        vm.prank(alice);
        stakingRewards.stake(amount1, 30 days);

        uint256 aliceBalanceAfterFirstStake = stakingToken.balanceOf(alice); 
        assertEq(aliceBalanceAfterFirstStake, aliceBalanceBeforeFirstStake - (amount1), "Alice should have staked the correct amount");

        // Alice tries to withdraw the first stake after 30 days but before 90 days
        vm.warp(block.timestamp + 31 days);
        vm.prank(alice);
        stakingRewards.withdraw(0);

        // Check if Alice's balance is updated correctly
        uint256 aliceBalanceAfterFirstWithdrawal = stakingToken.balanceOf(alice);
        console.log(stakingToken.balanceOf(alice));
        assertEq(aliceBalanceAfterFirstWithdrawal, aliceBalanceAfterFirstStake + amount1, "Alice should have withdrawn her first stake");
        
        vm.prank(alice);
        stakingRewards.stake(amount2, 90 days);


        (uint256 stakedAmount, uint256 stakedLockPeriod, uint256 stakedLockEnd) = stakingRewards.stakes(alice, 0);
        assertEq(stakedAmount, amount2, "Stake amount should be correct");

        // Alice tries to withdraw the second stake before its period ends
        vm.prank(alice);
        vm.expectRevert("Stake is locked");
        stakingRewards.withdraw(0);


        // Move time forward and withdraw the second stake
        vm.warp(block.timestamp + 90 days); // Total 61 days, beyond the second tier's lock
        vm.prank(alice);
        stakingRewards.withdraw(0);

        // Check final balance
        uint256 aliceFinalBalance = stakingToken.balanceOf(alice);
        assertEq(aliceFinalBalance, 1e18 * 1000, "Alice should have received all her staked tokens back");
    }

    function testGetReward() public {
        testNotifyRewardAmountByOwner();
        testStakeWithValidPeriod();
        uint256 initialBalance = rewardsToken.balanceOf(alice);
        vm.warp(block.timestamp + 31 days); // Move time to after the lock period
        vm.prank(alice);
        stakingRewards.getReward(); // Alice claims her rewards
        assertGt(rewardsToken.balanceOf(alice), initialBalance, "Alice should have received some rewards");
        console.log(rewardsToken.balanceOf(alice));
    }
}
