// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../StakingRewards.sol";
import "../RewardsDistributionRecipient.sol";

import "./ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract StakingRewardsTest is Test {
    StakingRewards public stakingRewards;
    address public owner;
    address public alice;
    address public bob;
    IERC20 public rewardsToken;
    IERC20 public stakingToken;

    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.envAddress("DEPLOYER");

    function setUp() public {

        owner = address(this);  // Typically the deploying address in tests
        alice = address(0x123);
        bob = address(0x456);

        // Assuming rewardsToken and stakingToken are already deployed and available at these addresses
        rewardsToken = IERC20(0xD83207C127c910e597b8ce77112ED0a56c8C9CD0);
        stakingToken = IERC20(0xD83207C127c910e597b8ce77112ED0a56c8C9CD0);

        // Deploy the StakingRewards contract
        stakingRewards = new StakingRewards(owner, address(rewardsToken));

        // Transfer ownership to a specific user if needed
        stakingRewards.transferOwnership(alice);

        // Set up initial token distribution and approvals
        if (vm.envAddress("DEPLOYER") != address(0)) {
            address deployer = vm.envAddress("DEPLOYER");
            uint256 deployerBalance = stakingToken.balanceOf(deployer);
            console.log("Deployer balance: ", deployerBalance);

            // Simulate transfers from the deployer or token holder to users and the contract
            vm.startBroadcast(privateKey);
            stakingToken.transfer(alice, 1e18 * 1_000_000_000);
            stakingToken.transfer(bob, 1e18 * 1_000_000_000);
            stakingToken.transfer(address(this), 1e18 * 20_000_000_000);
            rewardsToken.transfer(address(stakingRewards),1e18 * 5_000_000_000);
            stakingToken.approve(address(stakingRewards), type(uint256).max);
            rewardsToken.approve(address(stakingRewards), type(uint256).max);
            
            vm.stopBroadcast();  // Stop the impersonation of the deployer
        }

        // Mocking user actions with token approvals
        vm.prank(alice);
        stakingToken.approve(address(stakingRewards), type(uint256).max);
        vm.stopPrank();

        vm.prank(bob);
        stakingToken.approve(address(stakingRewards), type(uint256).max);

        vm.prank(alice);     
        stakingRewards.transferOwnership(address(this));

        vm.stopPrank();
    }

    function testNotifyRewardAmountByOwner() public {
        uint256 reward = 1e18 * 250_000_000_000;
        uint256 duration = 7 days;

        vm.prank(deployer);
        stakingRewards.notifyRewardAmount(reward);
        vm.stopPrank();

        uint256 expectedRewardRate = reward / duration;
        assertEq(stakingRewards.rewardRate(), expectedRewardRate, "Reward rate should be correctly updated");
    }

    function testFailNotifyRewardAmountByNonOwner() public {
        uint256 reward = 1e18 * 1000;
        uint256 duration = 365 days;
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
        (uint256 stakedAmount,,,) = stakingRewards.stakes(alice, 0);
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
        (uint256 stakedAmount1, uint256 stakedLockPeriod1,, uint256 stakedLockEnd1) = stakingRewards.stakes(alice, 0);
        assertEq(stakedAmount1, amount, "First stake amount should be correct");

        // Retrieve the entire struct as a tuple for the second stake
        (uint256 stakedAmount2, uint256 stakedLockPeriod2,, uint256 stakedLockEnd2) = stakingRewards.stakes(alice, 1);
        assertEq(stakedAmount2, amount * 2, "Second stake amount should be correct");
    }

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
        assertEq(aliceBalanceAfterFirstWithdrawal, aliceBalanceAfterFirstStake + amount1, "Alice should have withdrawn her first stake");
        
        vm.prank(alice);
        stakingRewards.stake(amount2, 90 days);

        (uint256 stakedAmount, uint256 stakedLockPeriod,, uint256 stakedLockEnd) = stakingRewards.stakes(alice, 0);
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
        uint256 aliceInitialBalance = 1_000_000_000 * 1e18;
        uint256 aliceFinalBalance = stakingToken.balanceOf(alice);

        assertEq(aliceFinalBalance, aliceInitialBalance, "Alice should have received all her staked tokens back");
    }

    function testWithdrawTier1ShouldFailLocked() public {
        uint256 amount = 1e18 * 100;
        vm.prank(alice);
        stakingRewards.stake(amount, 30 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 20 days); // Move time to before the lock period ends
        vm.prank(alice);
        vm.expectRevert("Stake is locked");
        stakingRewards.withdraw(0);
    }

    function testWithdrawTier2ShouldFailLocked() public {
        uint256 amount = 1e18 * 100;
        vm.prank(alice);
        stakingRewards.stake(amount, 90 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 80 days); // Move time to before the lock period ends
        vm.prank(alice);
        vm.expectRevert("Stake is locked");
        stakingRewards.withdraw(0);
    }

    function testWithdrawTier3ShouldFailLocked() public {
        uint256 amount = 1e18 * 100;
        vm.prank(alice);
        stakingRewards.stake(amount, 180 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 170 days); // Move time to before the lock period ends
        vm.prank(alice);
        vm.expectRevert("Stake is locked");
        stakingRewards.withdraw(0);
    }

    function testWithdrawTier4ShouldFailLocked() public {
        uint256 amount = 1e18 * 100;
        vm.prank(alice);
        stakingRewards.stake(amount, 30 days * 12);
        vm.stopPrank();

        vm.warp(block.timestamp + 359 days); // Move time to before the lock period ends
        vm.prank(alice);
        vm.expectRevert("Stake is locked");
        stakingRewards.withdraw(0);
    }

    function testGetRewardTier1() public {
        testNotifyRewardAmountByOwner();
        testStakeWithValidPeriod();
        uint256 initialBalance = rewardsToken.balanceOf(alice);
        vm.warp(block.timestamp + 31 days); // Move time to after the lock period
        vm.prank(alice);
        stakingRewards.getReward(); // Alice claims her rewards
        assertGt(rewardsToken.balanceOf(alice), initialBalance, "Alice should have received some rewards");
        console.log(rewardsToken.balanceOf(alice));
    }

    function stakeWithValidPeriod(uint256 amount, uint256 lockPeriod) public {
        vm.prank(alice);
        stakingRewards.stake(amount, lockPeriod);
        assertEq(stakingRewards.balanceOf(alice), amount, "Alice's staked balance should be 100 tokens");
        // Retrieve the entire struct as a tuple for the first stake
        (uint256 stakedAmount,,,) = stakingRewards.stakes(alice, 0);
        assertEq(stakedAmount, amount, "Stake amount should be correct");

    }

    function testGetRewardTier2() public {
        testNotifyRewardAmountByOwner();
        stakeWithValidPeriod(1e18 * 100, 90 days);
        uint256 initialBalance = rewardsToken.balanceOf(alice);
        vm.warp(block.timestamp + 91 days); // Move time to after the lock period
        vm.prank(alice);
        stakingRewards.getReward(); // Alice claims her rewards
        assertGt(rewardsToken.balanceOf(alice), initialBalance, "Alice should have received some rewards");
        console.log(rewardsToken.balanceOf(alice));
    }

    function testGetRewardTier3() public {
        testNotifyRewardAmountByOwner();
        stakeWithValidPeriod(1e18 * 100, 180 days);
        uint256 initialBalance = rewardsToken.balanceOf(alice);
        vm.warp(block.timestamp + 181 days); // Move time to after the lock period
        vm.prank(alice);
        stakingRewards.getReward(); // Alice claims her rewards
        assertGt(rewardsToken.balanceOf(alice), initialBalance, "Alice should have received some rewards");
        console.log(rewardsToken.balanceOf(alice));
    }

    function testGetRewardTier4() public {
        testNotifyRewardAmountByOwner();
        stakeWithValidPeriod(1e18 * 100, 30 days * 12);
        uint256 initialBalance = rewardsToken.balanceOf(alice);
        vm.warp(block.timestamp + 365 days); // Move time to after the lock period
        vm.prank(alice);
        stakingRewards.getReward(); // Alice claims her rewards
        assertGt(rewardsToken.balanceOf(alice), initialBalance, "Alice should have received some rewards");
        console.log(rewardsToken.balanceOf(alice));
    }
    
    function testRecoverERC20Owner() public {
        // First, ensure that only the owner can recover tokens
        // Simulate sending some ERC20 tokens to the staking contract
        uint256 amountToSend = 1e18 * 500;  // Send 500 tokens to the staking contract
        vm.prank(alice);
        rewardsToken.transfer(address(stakingRewards), amountToSend);

        // Check balance before recovery
        uint256 contractBalanceBefore = rewardsToken.balanceOf(address(stakingRewards));
        uint256 ownerBalanceBefore = rewardsToken.balanceOf(owner);

        // Attempt to recover tokens - this should be done by the owner
        vm.prank(owner);
        stakingRewards.recoverERC20(address(rewardsToken), amountToSend);

        // Verify that the tokens were successfully recovered
        uint256 contractBalanceAfter = rewardsToken.balanceOf(address(stakingRewards));
        uint256 ownerBalanceAfter = rewardsToken.balanceOf(owner);

        address owner = stakingRewards.owner();
        console.log(owner);
        console.log(address(this));

        assertEq(owner, address(this), "Owner should be the test contract");
        assertEq(contractBalanceBefore - amountToSend, contractBalanceAfter, "Contract should have 500 tokens less after recovery");
        assertEq(ownerBalanceBefore + amountToSend, ownerBalanceAfter, "Owner should have 500 tokens more after recovery");
    }

    function testRecoverERC20Deployer() public {
        // First, ensure that only the owner or deployer can recover tokens
        // Simulate sending some ERC20 tokens to the staking contract
        uint256 amountToSend = 1e18 * 500;  // Send 500 tokens to the staking contract
        vm.prank(alice);
        rewardsToken.transfer(address(stakingRewards), amountToSend);
        vm.stopPrank();

        // Check balance before recovery
        uint256 contractBalanceBefore = rewardsToken.balanceOf(address(stakingRewards));
        uint256 ownerBalanceBefore = rewardsToken.balanceOf(owner);

        // Attempt to recover tokens - this should be done by the owner
        vm.prank(address(this));
        stakingRewards.recoverERC20(address(rewardsToken), amountToSend);

        // Verify that the tokens were successfully recovered
        uint256 contractBalanceAfter = rewardsToken.balanceOf(address(stakingRewards));
        uint256 ownerBalanceAfter = rewardsToken.balanceOf(owner);

        address owner = stakingRewards.owner();
        console.log(owner);
        console.log(address(this));

        assertEq(owner, address(this), "Owner should be the test contract");
        assertEq(contractBalanceBefore - amountToSend, contractBalanceAfter, "Contract should have 500 tokens less after recovery");
        assertEq(ownerBalanceBefore + amountToSend, ownerBalanceAfter, "Owner should have 500 tokens more after recovery");
    }

    function testRecoverPerezosoToken() public {
        // First, ensure that only the owner or deployer can recover tokens
        // Simulate sending some ERC20 tokens to the staking contract
        uint256 amountToSend = 1e18 * 5000;  
        vm.prank(alice);
        rewardsToken.transfer(address(stakingRewards), amountToSend);
        vm.stopPrank();

        // Check balance before recovery
        uint256 contractBalanceBefore = rewardsToken.balanceOf(address(stakingRewards));
        uint256 ownerBalanceBefore = rewardsToken.balanceOf(owner);

        // Attempt to recover tokens - this should be done by the owner
        vm.prank(address(this));
        stakingRewards.recoverPerezosoToken();

        // Verify that the tokens were successfully recovered
        uint256 contractBalanceAfter = rewardsToken.balanceOf(address(stakingRewards));
        uint256 ownerBalanceAfter = rewardsToken.balanceOf(owner);

        address owner = stakingRewards.owner();

        assertEq(owner, address(this), "Owner should be the test contract");
        
        assertTrue(contractBalanceBefore > contractBalanceAfter, "Contract should have less tokens after recovery");
        assertTrue(ownerBalanceBefore < ownerBalanceAfter, "Owner should have more tokens after recovery");
    }

    function testWithdrawalLimit() public {
        // Setup
        testNotifyRewardAmountByOwner();

        uint256 MAX_WITHDRAWAL_AMOUNT = 20_000_000_000 * 1e18;
        uint256 balance = stakingToken.balanceOf(address(this));

        assertEq(MAX_WITHDRAWAL_AMOUNT, balance, "Contract balance should match the max withdrawal amount");

        uint256 amount = 1_000_000 * 1e18;

        vm.prank(alice);
        stakingRewards.stake(amount, 30 days);
        vm.warp(block.timestamp + 3 days + 1); // Fast forward time to ensure withdrawal is valid
        
        uint256 aliceBalanceBefore = rewardsToken.balanceOf(alice);

        vm.prank(alice);
        stakingRewards.getReward();  // Attempt to withdraw which should respect the max limit

        // Validation
        uint256 aliceBalanceAfter = rewardsToken.balanceOf(alice);
        
        uint256 balancesDelta = aliceBalanceAfter - aliceBalanceBefore;
        assertTrue(balancesDelta <= MAX_WITHDRAWAL_AMOUNT, "Alice should have received the max withdrawal amount");
    }
        
    function testWithdrawalOncePerDay() public {
        testNotifyRewardAmountByOwner();

        uint256 amount = 1_000_000 * 1e18;

        vm.startPrank(alice);
        stakingRewards.stake(amount, 180 days);
        vm.warp(block.timestamp + 60 days); // Fast forward time to ensure withdrawal is valid

        stakingRewards.getReward(); // First withdrawal, should succeed.

        uint256 lastTime = stakingRewards.lastWithdrawalTime(alice);
        console.log("Last Withdrawal Time:", lastTime);

        vm.warp(block.timestamp + 12 hours); 
        console.log(block.timestamp + 12 hours);

        vm.expectRevert("Withdrawal can only be done once a day");
        stakingRewards.getReward(); // Second attempt should fail but does not

        vm.stopPrank();
    }

    function testSetMaxWithdrawalAmount() public {
        uint256 newLimit = 1e18 * 500; // Set a new lower limit

        // Only owner can set new withdrawal amount
        vm.prank(owner);
        stakingRewards.setMaxWithdrawalAmount(newLimit);
        assertEq(stakingRewards.MAX_WITHDRAWAL_AMOUNT(), newLimit, "Max withdrawal amount should be updated");

        // Ensure no other account can change it
        vm.prank(alice);
        vm.expectRevert("Caller is not the owner or deployer");
        stakingRewards.setMaxWithdrawalAmount(newLimit);
    }

    function testSetDuration() public {
        uint256 newDuration = 14 days; // Set a new duration

        // Only owner can set new duration
        vm.prank(owner);
        stakingRewards.setDuration(newDuration);
        assertEq(stakingRewards.DURATION(), newDuration, "Duration should be updated");

        stakingToken.approve(address(stakingRewards), type(uint256).max);
        // Ensure the duration cannot be changed after rewards distribution starts
        stakingRewards.notifyRewardAmount(1e18); // Start reward distribution
        vm.prank(owner);
        vm.expectRevert("Cannot change duration after rewards distribution has started");
        stakingRewards.setDuration(10 days);
    }

}
