// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../StakingRewardsV4.sol";
import "../RewardsDistributionRecipient.sol";
import "../RewardEscrow.sol"; 
import "../SafeMath.sol";

import "./ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract V4 is Test {
    using SafeMath for uint256;

    StakingRewardsV4 public stakingRewards;
    RewardEscrow public rewardEscrow;
    address public owner;
    address public alice;
    address public bob;
    address public delegatee;
    IERC20 public rewardsToken;
    IERC20 public stakingToken;

    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.envAddress("DEPLOYER");

    function setUp() public {

        owner = address(this);  // Typically the deploying address in tests
        alice = address(0x123);
        bob = address(0x456);
        delegatee = address(0x567);

        // Assuming rewardsToken and stakingToken are already deployed and available at these addresses
        rewardsToken = IERC20(0x4532547919aBbA30b3e4264087E522c923269754);
        stakingToken = IERC20(0xD83207C127c910e597b8ce77112ED0a56c8C9CD0);


        // Deploy the StakingRewards contract
        stakingRewards = new StakingRewardsV4(owner, address(rewardsToken), address(stakingToken));

        rewardEscrow = new RewardEscrow(rewardsToken);
        stakingRewards.setRewardEscrow(address(rewardEscrow));

        rewardEscrow = stakingRewards.rewardEscrow();

        // Transfer ownership to a specific user if needed
        stakingRewards.transferOwnership(alice);
        
        
        // Set up initial token distribution and approvals
        if (vm.envAddress("DEPLOYER") != address(0)) {
            address deployer = vm.envAddress("DEPLOYER");

            vm.startBroadcast(alice);
            stakingRewards.activateGetRewards();
            stakingRewards.setReferrals(true);
            vm.stopBroadcast();

            // Simulate transfers from the deployer or token holder to users and the contract
            vm.startBroadcast(deployer);
            stakingToken.transfer(owner, 1e18 * 1_500_000_000);
            stakingToken.transfer(alice, 1e18 * 1_500_000_000_000);
            stakingToken.transfer(bob, 1e18 * 1_500_000_000);
            stakingToken.transfer(address(this), 1e18 * 20_000_000_000);
            rewardsToken.transfer(address(stakingRewards),1e18 * 15_000_000);
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

    function testBalance() public {
        uint256 deployerBalanceStakingToken = stakingToken.balanceOf(deployer);
        uint256 deployerBalanceRewardToken = rewardsToken.balanceOf(deployer);

        console.log("Deployer balance stakingToken: ", deployerBalanceStakingToken);
        console.log("Deployer balance rewardToken: ", deployerBalanceRewardToken);  

    }

    function testNotifyRewardAmountByOwner() public {
        uint256 reward = 1e18 * 250_000;
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
        uint256 lockPeriod = 180 days;
        uint256 amount = 1e18 * 100;
        vm.prank(alice);
        stakingRewards.stake(amount, lockPeriod);
        assertEq(stakingRewards.balanceOf(alice), amount, "Alice's staked balance should be 100 tokens");
        // Retrieve the entire struct as a tuple for the first stake
        (uint256 stakedAmount,,,,) = stakingRewards.stakes(alice, 0);
        assertEq(stakedAmount, amount, "Stake amount should be correct");

    }

    function testStakeByRef() public {
        uint256 amount = 1e18 * 100;
        uint256 lockPeriod = 180 days;
        
        // Initial balances and referral count
        uint256 initialBalanceDeployer = stakingToken.balanceOf(deployer);
        uint256 initialReferralCount = stakingRewards.getReferralCount(deployer);

        // Alice stakes with deployer as referrer
        vm.prank(alice);
        stakingRewards.stakeByRef(amount, lockPeriod, deployer);

        // Verify the stake
        (uint256 stakedAmount, uint256 stakedLockPeriod, uint256 multiplier, uint256 lockEnd,) = stakingRewards.stakes(alice, 0);
        assertEq(stakedAmount, amount, "Staked amount should match");
        assertEq(stakedLockPeriod, lockPeriod, "Lock period should match");
        assertEq(multiplier, stakingRewards.lockMultipliers(stakingRewards.lockPeriods(lockPeriod)), "Multiplier should match");
        assertEq(lockEnd, block.timestamp + lockPeriod, "Lock end should be correct");

        // Verify referral count and staked amount for the referrer
        uint256 newReferralCount = stakingRewards.getReferralCount(deployer);
        uint256 referralStakedAmount = stakingRewards.referralStaked(deployer);
        
        assertEq(newReferralCount, initialReferralCount + 1, "Referral count should increase by 1");
        assertEq(referralStakedAmount, amount, "Referral staked amount should match the staked amount");

        // Verify token transfer
        uint256 newBalanceDeployer = stakingToken.balanceOf(deployer);
        assertEq(newBalanceDeployer, initialBalanceDeployer, "Deployer balance should not change");

        // Verify Alice's staking balance
        uint256 aliceBalance = stakingRewards.balanceOf(alice);
        assertEq(aliceBalance, amount, "Alice's staking balance should be updated");

        // Verify Alice's token balance
        uint256 aliceTokenBalance = stakingToken.balanceOf(alice);
        assertEq(aliceTokenBalance, 1_500_000_000_000 * 1e18 - amount, "Alice's token balance should be reduced by the staked amount");
    }

    function testMultipleStakes() public {
        uint256 amount = 1e18 * 100;
        uint256 lockPeriod1 = 180 days;
        uint256 lockPeriod2 = 360 days;
        vm.startPrank(alice);
        stakingRewards.stake(amount, lockPeriod1);
        stakingRewards.stake(amount * 2, lockPeriod2);
        vm.stopPrank();

        // Retrieve the entire struct as a tuple for the first stake
        (uint256 stakedAmount1, uint256 stakedLockPeriod1,, uint256 stakedLockEnd1,) = stakingRewards.stakes(alice, 0);
        assertEq(stakedAmount1, amount, "First stake amount should be correct");

        // Retrieve the entire struct as a tuple for the second stake
        (uint256 stakedAmount2, uint256 stakedLockPeriod2,, uint256 stakedLockEnd2,) = stakingRewards.stakes(alice, 1);
        assertEq(stakedAmount2, amount * 2, "Second stake amount should be correct");
    }

   function testWithdraw() public {
        // First, Alice stakes some tokens
        uint256 amount = 1e18 * 100;
        uint256 aliceInitialBalance = stakingToken.balanceOf(alice);

        vm.prank(alice);
        stakingRewards.stake(amount, 180 days);

        // Attempt to withdraw before the lock period ends
        vm.warp(block.timestamp + 160 days); // Move time to before the lock period ends
        vm.prank(alice);
        vm.expectRevert("Stake is locked");
        stakingRewards.withdraw(0);

        // Warp to after the lock period and try to withdraw
        vm.warp(block.timestamp + 21 days); // Move time to after the lock period
        vm.prank(alice);
        stakingRewards.withdraw(0);

        uint256 aliceFinalBalance = stakingToken.balanceOf(alice);
        assertEq(aliceFinalBalance, aliceInitialBalance, "Alice should have all her staked tokens back after withdrawal");

        // Check if the staking balance reflects the withdrawal
        assertEq(stakingRewards.balanceOf(alice), 0, "Alice's staking balance should be zero after withdrawal");
    }

    function testStakeByRefNotActivated() public {
        uint256 amount = 1e18 * 100;
        uint256 lockPeriod = 180 days;

        stakingRewards.setReferrals(false);

        // Ensure referrals are not activated
        require(!stakingRewards.referralsActivated(), "Referrals should not be activated");

        // Attempt to stake with referral, expecting it to revert
        vm.prank(alice);
        vm.expectRevert("Referrals not activated yet");
        stakingRewards.stakeByRef(amount, lockPeriod, deployer);
    }

        
    function testReferralRewards() public {
        uint256 amount = 1e18 * 100;
        uint256 lockPeriod = 180 days;

        // Alice stakes with deployer as referrer
        vm.prank(alice);
        stakingRewards.stakeByRef(amount, lockPeriod, deployer);

        // Notify reward amount
        uint256 reward = 1e18 * 250_000;
        uint256 duration = 7 days;
        vm.prank(deployer);
        stakingRewards.notifyRewardAmount(reward);
        vm.stopPrank();

        // Bob stakes with Alice as referrer
        vm.prank(bob);
        stakingRewards.stakeByRef(amount, lockPeriod, alice);

        // Fast forward time to after the lock period
        vm.warp(block.timestamp + 221 days);

        // Initial balances
        uint256 initialBalanceAlice = rewardsToken.balanceOf(alice);
        uint256 initialBalanceDeployer = rewardsToken.balanceOf(deployer);

        vm.prank(deployer);
        stakingRewards.claimReferralRewards();

        // Final balances
        uint256 finalBalanceDeployer = rewardsToken.balanceOf(deployer);

        // Validate referral rewards
        uint256 expectedReferralReward = stakingRewards.referralRewards(deployer); // Fetch the expected referral reward
        uint256 actualReferralReward = finalBalanceDeployer - initialBalanceDeployer;

        assertEq(actualReferralReward, expectedReferralReward, "Deployer should have received the referral reward");
    }

    function testEscrowInitialization() public {
        uint256 amount = 1e18 * 100_000_000_000;
        uint256 lockPeriod = 180 days;

        // Alice stakes
        vm.prank(alice);
        stakingRewards.stake(amount, lockPeriod);

        // Notify reward amount
        uint256 reward = 1e18 * 150_000;
        uint256 duration = 7 days;
        vm.prank(deployer);
        stakingRewards.notifyRewardAmount(reward);
        vm.stopPrank();

        // Activate escrow
        // vm.prank(deployer);
        stakingRewards.activateEscrow();
        // vm.stopPrank();
        require(stakingRewards.escrowActivated() == true, "escrow not activated");
        // Fast forward time to after the lock period
        vm.warp(block.timestamp + 180 days);
        uint256 rewardEarned = stakingRewards.earned(alice);

        // Alice claims her rewards
        vm.prank(alice);
        stakingRewards.getReward();

        uint256 totalEscrowPositionByUser = rewardEscrow.getTotalEscrowPositionsByUser(alice);
        assertEq(totalEscrowPositionByUser, 3, "Alice should have 3 escrow positions");

        // Check escrow entries
        (uint256 totalEscrowed,,) = rewardEscrow.getEscrowDetails(alice, 0);
        console.log("total escrowed is %d", totalEscrowed);

        RewardEscrow.Escrow[] memory escrowPositions = rewardEscrow.getEscrowPositions(alice);
        
        assertEq(totalEscrowed, rewardEarned.div(3), "Escrow should be initialized with one-third of the rewards");

        // Fast forward time to the first release time
        vm.warp(block.timestamp + 30 days);

        // Alice withdraws from escrow
        vm.prank(alice);
        rewardEscrow.withdrawEscrow(0);

        uint256 balanceAfterFirstWithdrawal = rewardsToken.balanceOf(alice);
        assertApproxEqAbs(balanceAfterFirstWithdrawal, reward.div(3), reward.div(3), "Alice should receive one-third of the rewards");
 
        // Repeat for subsequent release times
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        rewardEscrow.withdrawEscrow(1);

        uint256 balanceAfterSecondWithdrawal = rewardsToken.balanceOf(alice);
        assertApproxEqAbs(balanceAfterSecondWithdrawal, reward.mul(2).div(3),  reward.mul(2).div(3), "Alice should receive two-thirds of the rewards");

        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        rewardEscrow.withdrawEscrow(2);

        uint256 balanceAfterThirdWithdrawal = rewardsToken.balanceOf(alice);
        assertApproxEqAbs(balanceAfterThirdWithdrawal, reward, reward, "Alice should receive all the rewards");
    }


    function testEarned() public {
        // Notify reward amount
        uint256 reward = 1e18 * 250_000;
        vm.prank(deployer);
        stakingRewards.notifyRewardAmount(reward);
        vm.stopPrank();

        // Stake some tokens
        uint256 stakeAmount = 1e18 * 100;
        uint256 lockPeriod = 180 days;
        vm.prank(alice);
        stakingRewards.stake(stakeAmount, lockPeriod);

        // Advance time to half the reward duration
        vm.warp(block.timestamp + 3.5 days);

        // Calculate expected earned rewards
        uint256 expectedEarned = (reward / 7 days) * 3.5 days;

        // Get earned rewards from contract
        uint256 earnedRewards = stakingRewards.earned(alice);

        // Check that the earned rewards match the expected amount
        assertApproxEqAbs(earnedRewards, expectedEarned, 1e18, "Earned rewards should match the expected amount");
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
        stakingRewards.stake(amount, 360 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 359 days); // Move time to before the lock period ends
        vm.prank(alice);
        vm.expectRevert("Stake is locked");
        stakingRewards.withdraw(0);
    }


    function stakeWithValidPeriod(uint256 amount, uint256 lockPeriod) public {
        vm.prank(alice);
        stakingRewards.stake(amount, lockPeriod);
        assertEq(stakingRewards.balanceOf(alice), amount, "Alice's staked balance should be 100 tokens");
        // Retrieve the entire struct as a tuple for the first stake
        (uint256 stakedAmount,,,,) = stakingRewards.stakes(alice, 0);
        assertEq(stakedAmount, amount, "Stake amount should be correct");

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
        stakeWithValidPeriod(1e18 * 100, 360 days);
        uint256 initialBalance = rewardsToken.balanceOf(alice);
        vm.warp(block.timestamp + 361 days); // Move time to after the lock period
        vm.prank(alice);
        stakingRewards.getReward(); // Alice claims her rewards
        assertGt(rewardsToken.balanceOf(alice), initialBalance, "Alice should have received some rewards");
        console.log(rewardsToken.balanceOf(alice));
    }
    
    function testRecoverPerezosoToken() public {
        // First, ensure that only the owner or deployer can recover tokens
        // Simulate sending some ERC20 tokens to the staking contract
        uint256 amountToSend = 1e18 * 5000;  
        vm.prank(alice);
        stakingToken.transfer(address(stakingRewards), amountToSend);
        vm.stopPrank();

        // Check balance before recovery
        uint256 contractBalanceBefore = stakingToken.balanceOf(address(stakingRewards));
        uint256 ownerBalanceBefore = stakingToken.balanceOf(owner);

        // Attempt to recover tokens - this should be done by the owner
        vm.prank(address(this));
        stakingRewards.recoverPerezosoToken();

        // Verify that the tokens were successfully recovered
        uint256 contractBalanceAfter = stakingToken.balanceOf(address(stakingRewards));
        uint256 ownerBalanceAfter = stakingToken.balanceOf(owner);

        address owner = stakingRewards.owner();

        assertEq(owner, address(this), "Owner should be the test contract");
        
        assertTrue(contractBalanceBefore > contractBalanceAfter, "Contract should have less tokens after recovery");
        assertTrue(ownerBalanceBefore < ownerBalanceAfter, "Owner should have more tokens after recovery");
    }

    function testRecoverBabyPerezosoToken() public {
        vm.startBroadcast(deployer);
        rewardsToken.transfer(address(alice),1e18 * 5000);
        vm.stopBroadcast();

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
        stakingRewards.recoverBabyPerezosoToken();

        // Verify that the tokens were successfully recovered
        uint256 contractBalanceAfter = rewardsToken.balanceOf(address(stakingRewards));
        uint256 ownerBalanceAfter = rewardsToken.balanceOf(owner);

        address owner = stakingRewards.owner();

        assertEq(owner, address(this), "Owner should be the test contract");
        
        assertTrue(contractBalanceBefore > contractBalanceAfter, "Contract should have less tokens after recovery");
        assertTrue(ownerBalanceBefore < ownerBalanceAfter, "Owner should have more tokens after recovery");
    }
    
    function testStakeInvalidPeriod() public {
        uint256 lockPeriod = 90 days;
        uint256 amount = 1e18 * 100;
        vm.prank(alice);

        vm.expectRevert("Invalid lock period");
        stakingRewards.stake(amount, lockPeriod);
    }

    function testDelegatePosition() public {
        uint256 amount = 100 ether;
        uint256 lockPeriod = 180 days;

        // Alice stakes tokens
        vm.prank(alice);
        stakingRewards.stake(amount, lockPeriod);

        // Delegate position to delegatee
        vm.prank(alice);
        stakingRewards.delegatePosition(0, delegatee);

        // Check if delegatee is in the owners list
        StakingRewardsV4.Stake[] memory stakes = stakingRewards.getAllStakes(alice);
        bool isDelegatee = false;
        for (uint256 i = 0; i < stakes[0].owners.length; i++) {
            if (stakes[0].owners[i] == delegatee) {
                isDelegatee = true;
                break;
            }
        }
        assertTrue(isDelegatee, "Delegatee should be in the owners list");
        vm.warp(block.timestamp + 181 days); // Move time to after the lock period

        // Check if delegatee can interact with the stake
        vm.startPrank(delegatee);
        stakingRewards.delegateWithdraw(0, alice);
        vm.stopPrank();

    }

    function testPositionNotEarningAfterExpiration() public {
        uint256 amount = 100 ether;
        uint256 lockPeriod = 180 days;
        uint256 rewardAmount = 1000 ether;
        uint256 duration = 7 days;

        // Alice stakes tokens
        vm.prank(alice);
        stakingRewards.stake(amount, lockPeriod);

        // Notify reward amount
        vm.prank(deployer);
        stakingRewards.notifyRewardAmount(rewardAmount);

        // Fast forward time to just before the lock period expires
        vm.warp(block.timestamp + lockPeriod - 1);
        uint256 earnedBeforeExpiration = stakingRewards.earned(alice);

        // Fast forward time to after the lock period expires
        vm.warp(block.timestamp + 7 days);
        uint256 earnedAfterExpiration = stakingRewards.earned(alice);

        vm.warp(block.timestamp + 7 days); 
        uint256 earnedAfterExpiration1 = stakingRewards.earned(alice);

        vm.warp(block.timestamp + 7 days);
        uint256 earnedAfterExpiration2 = stakingRewards.earned(alice);

        assertEq(earnedAfterExpiration, earnedAfterExpiration1, "position still earning");
        assertEq(earnedAfterExpiration1, earnedAfterExpiration2, "position still earning");
    }

}
