// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./RewardsDistributionRecipient.sol";
import "./TokenWrapper.sol";
import "./RewardEscrow.sol";
import "./SafeMath.sol";

contract StakingRewardsV4 is TokenWrapper, RewardsDistributionRecipient, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    RewardEscrow public rewardEscrow;
    IERC20 public babyPerezoso; // Reward token (BBP)
    IERC20 public przs; // Staking token (PRZS)
    uint256 public DURATION = 7 days;

    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    address[] public stakers;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    mapping(address => Stake[]) public stakes;
    mapping(uint256 => uint256) public lockPeriods;
    mapping(uint256 => uint256) public lockMultipliers;

    uint256 private _totalSupply;
    uint256 public totalStakers;

    mapping(address => uint256) private _balances;
    mapping(address => uint256) public lastWithdrawalTime;
    mapping(address => bool) public isStaker;
    mapping(address => uint256) public rewardPaid;

    mapping(address => uint256) public totalReferralStaked;
    mapping(address => uint256) public referralRewards;
    mapping(address => uint256) public totalStakedByReferral;
    mapping(address => mapping(address => uint256)) public referralStakes; // referrer -> staker -> amount
    mapping(address => bool) public referralRewardClaimed; // Track if referral reward has been claimed

    mapping(address => address) public referredBy; // Maps staker to referrer
    mapping(address => uint256) public referralCount; // Count of referrals by referrer
    mapping(address => uint256) public referralStaked; // Total staked by referrals

    address public deployer;
    address public rewardEscrowAddress;

    bool public importedStakes;
    bool public escrowActivated;
    bool public referralsActivated;
    bool public getRewardsActivated;

    struct Stake {
        uint256 amount;
        uint256 lockPeriod;
        uint256 multiplier;
        uint256 lockEnd;
        uint256 totalEarned;
        address[] owners;
    }

    struct RewardEntry {
        uint256 totalEscrowed;
        uint256 releaseTime1;
        uint256 releaseTime2;
        uint256 releaseTime3;
        bool withdrawn1;
        bool withdrawn2;
        bool withdrawn3;
    }

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount, uint256 lockPeriod);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event TokensRecovered(address token, uint256 amount);
    event StakedByReferral(address indexed user, address indexed referrer, uint256 amount, uint256 lockPeriod);

    constructor(address _owner, address _babyPerezoso, address _przs)
        Ownable(_owner)
        TokenWrapper(_przs)
    {
        babyPerezoso = IERC20(_babyPerezoso); // Reward token (BBP)
        przs = IERC20(_przs); // Staking token (PRZS)
        deployer = msg.sender;

        lockPeriods[30 days] = 1;
        lockPeriods[90 days] = 2;
        lockPeriods[180 days] = 3;
        lockPeriods[360 days] = 6;

        lockMultipliers[1] = 1;
        lockMultipliers[2] = 2;
        lockMultipliers[3] = 1;
        lockMultipliers[6] = 2;
    }

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function weightedTotalSupply() public view returns (uint256) {
        uint256 totalWeightedSupply = 0;
        for (uint256 i = 0; i < stakers.length; i++) {
            address staker = stakers[i];
            for (uint256 j = 0; j < stakes[staker].length; j++) {
                totalWeightedSupply = totalWeightedSupply.add(stakes[staker][j].amount.mul(stakes[staker][j].multiplier));
            }
        }
        return totalWeightedSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint256) {
        uint256 weightedSupply = weightedTotalSupply();
        if (weightedSupply == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored.add(
            lastTimeRewardApplicable()
                .sub(lastUpdateTime)
                .mul(rewardRate)
                .mul(1e18)
                .div(weightedSupply)
        );
    }

    function earned(address account) public view returns (uint256) {
        uint256 totalEarnedAmount = 0;
        for (uint256 i = 0; i < stakes[account].length; i++) {
            totalEarnedAmount = totalEarnedAmount.add(earnedOnStake(account, i));
        }
        return totalEarnedAmount.sub(rewardPaid[account]);
    }

    function earnedOnStake(address account, uint256 index) public view returns (uint256) {
        require(index < stakes[account].length, "Stake index out of bounds");
        Stake storage stake = stakes[account][index];

        uint256 applicableRewardPerToken = rewardPerToken();
        uint256 rewardDelta = applicableRewardPerToken.sub(userRewardPerTokenPaid[account]);

        uint256 newEarnedAmount = stake.amount.mul(rewardDelta).div(1e18).mul(stake.multiplier);

        if (block.timestamp <= stake.lockEnd) {
            return stake.totalEarned.add(newEarnedAmount);
        } else {
            // Calculate rewards until lock end
            uint256 rewardUntilLockEnd = stake.amount.mul(stake.lockEnd.sub(lastUpdateTime)).mul(rewardRate).div(weightedTotalSupply()).div(1e18).mul(stake.multiplier);
            return stake.totalEarned.add(rewardUntilLockEnd);
        }
    }

    function stakesCount(address user) public view returns (uint256) {
        return stakes[user].length;
    }

    function getAllStakes(address user) public view returns (Stake[] memory) {
        return stakes[user];
    }

    function stake(uint256 amount, uint256 lockPeriod) public updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        require(lockPeriods[lockPeriod] >= 3, "Invalid lock period");

        address[] memory ownersList = new address[](1);
        ownersList[0] = msg.sender;

        uint256 multiplier = lockMultipliers[lockPeriods[lockPeriod]];
        stakes[msg.sender].push(Stake(amount, lockPeriod, multiplier, block.timestamp + lockPeriod, 0, ownersList));

        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        lastWithdrawalTime[msg.sender] = 0;

        if (!isStaker[msg.sender]) {
            stakers.push(msg.sender);
            isStaker[msg.sender] = true;
            totalStakers = totalStakers.add(1);
        }

        przs.safeTransferFrom(msg.sender, address(this), amount); // Transfer staking tokens
        emit Staked(msg.sender, amount, lockPeriod);
    }

    function stakeByRef(uint256 amount, uint256 lockPeriod, address referrer) public updateReward(msg.sender) {
        require(referralsActivated, "Referrals not activated yet");
        require(amount > 0, "Cannot stake 0");
        require(lockPeriods[lockPeriod] >= 3, "Invalid lock period");

        require(referrer != msg.sender, "Referrer cannot be the staker");
        require(referrer != address(0), "Invalid referrer address");

        if (referredBy[msg.sender] == address(0)) {
            referredBy[msg.sender] = referrer;
            referralCount[referrer] = referralCount[referrer].add(1);
        }
        referralStaked[referrer] = referralStaked[referrer].add(amount);
        totalStakedByReferral[referrer] = totalStakedByReferral[referrer].add(amount);
        referralStakes[referrer][msg.sender] = referralStakes[referrer][msg.sender].add(amount);

        address[] memory ownersList = new address[](1);
        ownersList[0] = msg.sender;

        uint256 multiplier = lockMultipliers[lockPeriods[lockPeriod]];
        stakes[msg.sender].push(Stake(amount, lockPeriod, multiplier, block.timestamp + lockPeriod, 0, ownersList));

        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        lastWithdrawalTime[msg.sender] = 0;

        if (!isStaker[msg.sender]) {
            stakers.push(msg.sender);
            isStaker[msg.sender] = true;
            totalStakers = totalStakers.add(1);
        }

        przs.safeTransferFrom(msg.sender, address(this), amount);
        emit StakedByReferral(msg.sender, referrer, amount, lockPeriod);
    }

    function withdraw(uint256 stakeIndex) public override updateReward(msg.sender) {
        require(stakeIndex < stakes[msg.sender].length, "Invalid stake index");
        Stake storage stake = stakes[msg.sender][stakeIndex];

        require(stake.amount > 0, "No stake to withdraw");
        require(block.timestamp >= stake.lockEnd, "Stake is locked");

        require(isOwner(stake, msg.sender), "Caller is not the stake owner");

        _totalSupply = _totalSupply.sub(stake.amount);
        _balances[msg.sender] = _balances[msg.sender].sub(stake.amount);
        przs.safeTransfer(msg.sender, stake.amount); // Transfer staking tokens back
        emit Withdrawn(msg.sender, stake.amount);

        stakes[msg.sender][stakeIndex] = stakes[msg.sender][stakes[msg.sender].length - 1];
        stakes[msg.sender].pop();
        totalStakers = totalStakers.sub(1);
    }

    function delegateWithdraw(uint256 stakeIndex, address staker) public updateReward(staker) {
        require(stakeIndex < stakes[staker].length, "Invalid stake index");
        Stake storage stake = stakes[staker][stakeIndex];

        require(stake.amount > 0, "No stake to withdraw");
        require(block.timestamp >= stake.lockEnd, "Stake is locked");

        bool isDelegatee = false;
        for (uint256 i = 0; i < stake.owners.length; i++) {
            if (stake.owners[i] == msg.sender) {
                isDelegatee = true;
                break;
            }
        }
        require(isDelegatee, "Caller is not authorized to withdraw");

        _totalSupply = _totalSupply.sub(stake.amount);
        _balances[staker] = _balances[staker].sub(stake.amount);
        przs.safeTransfer(staker, stake.amount); // Transfer staking tokens back to staker
        emit Withdrawn(staker, stake.amount);

        stakes[staker][stakeIndex] = stakes[staker][stakes[staker].length - 1];
        stakes[staker].pop();
        totalStakers = totalStakers.sub(1);
    }


    function notifyRewardAmount(uint256 _amount)
        external
        override
        onlyRewardsDistribution
        updateReward(address(0))
    {
        if (block.timestamp >= periodFinish) {
            rewardRate = _amount.div(DURATION);
        } else {
            uint256 remainingTime = periodFinish.sub(block.timestamp);
            uint256 leftoverReward = remainingTime.mul(rewardRate);
            uint256 newRewardRate = _amount.add(leftoverReward).div(DURATION);
            require(newRewardRate >= rewardRate, "New reward rate too low");
            rewardRate = newRewardRate;
        }

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(DURATION);

        babyPerezoso.safeTransferFrom(msg.sender, address(this), _amount); // Transfer reward tokens
        emit RewardAdded(_amount);
    }

    function delegatePosition(uint256 stakeIndex, address delegatee) external {
        require(delegatee != address(0), "Invalid delegatee address");
        require(stakeIndex < stakes[msg.sender].length, "Invalid stake index");
        
        Stake storage stake = stakes[msg.sender][stakeIndex];
        require(isOwner(stake, msg.sender), "Caller is not the stake owner");

        stake.owners.push(delegatee);
    }

    function getReferralCount(address referrer) external view returns (uint256) {
        return referralCount[referrer];
    }

    function getReferralStaked(address referrer) external view returns (uint256) {
        return referralStaked[referrer];
    }

    function getReferrer(address staker) external view returns (address) {
        return referredBy[staker];
    }
        
    function getReward() public updateReward(msg.sender) {
        require(getRewardsActivated, "Get rewards not activated yet");

        uint256 reward = earned(msg.sender);
        require(reward > 0, "No rewards to claim");

        uint256 totalReleased = reward;
        uint256 currentTime = block.timestamp;

        if (escrowActivated) {
            uint256[] memory amounts = new uint256[](3);
            uint256[] memory releaseTimes = new uint256[](3);

            amounts[0] = reward.div(3);
            amounts[1] = reward.div(3);
            amounts[2] = reward.sub(amounts[0]).sub(amounts[1]);

            releaseTimes[0] = currentTime + 30 days;
            releaseTimes[1] = currentTime + 60 days;
            releaseTimes[2] = currentTime + 90 days;

            rewardEscrow.createEscrows(msg.sender, amounts, releaseTimes);
            babyPerezoso.safeTransfer(address(rewardEscrow), reward);
            totalReleased = 0;
        }

        rewards[msg.sender] = rewards[msg.sender].sub(totalReleased);
        rewardPaid[msg.sender] = rewardPaid[msg.sender].add(totalReleased);
        lastWithdrawalTime[msg.sender] = currentTime;

        if (totalReleased > 0) {
            babyPerezoso.safeTransfer(msg.sender, totalReleased);
            emit RewardPaid(msg.sender, totalReleased);
        }
    }

    function getTotalStakedByReferral(address referrer) public view returns (uint256) {
        uint256 totalStaked = 0;
        for (uint256 i = 0; i < stakers.length; i++) {
            address staker = stakers[i];
            if (referredBy[staker] == referrer) {
                totalStaked = totalStaked.add(_balances[staker]);
            }
        }
        return totalStaked;
    }

    function recoverBabyPerezosoToken() external onlyOwnerOrDeployer {
        uint256 amountToRecover = babyPerezoso.balanceOf(address(this));
        babyPerezoso.safeTransfer(owner(), amountToRecover);
        emit TokensRecovered(address(babyPerezoso), amountToRecover);
    }

    function recoverPerezosoToken() external onlyOwnerOrDeployer {
        uint256 amountToRecover = przs.balanceOf(address(this));
        przs.safeTransfer(owner(), amountToRecover);
        emit TokensRecovered(address(przs), amountToRecover);
    }

    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwnerOrDeployer {
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit TokensRecovered(tokenAddress, tokenAmount);
    }

    function setDuration(uint256 _duration) external onlyOwnerOrDeployer {
        require(periodFinish == 0, "Cannot change duration after rewards distribution has started");
        require(_duration > 0, "Duration must be greater than 0");
        DURATION = _duration;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            for (uint256 i = 0; i < stakes[account].length; i++) {
                Stake storage stake = stakes[account][i];
                uint256 earnedAmount = earnedOnStake(account, i);
                if (block.timestamp <= stake.lockEnd) {
                    stakes[account][i].totalEarned = earnedAmount;
                }
            }
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function calculateReferralRewards(address referrer) public {
        uint256 totalStakedByReferral = totalStakedByReferral[referrer];

        if (totalStakedByReferral < 10_000_000_000 * 1e18) {
            referralRewards[referrer] = 100 * 1e18;
        } else if (totalStakedByReferral < 50_000_000_000 * 1e18) {
            referralRewards[referrer] = 500 * 1e18;
        } else if (totalStakedByReferral < 100_000_000_000 * 1e18) {
            referralRewards[referrer] = 1_000 * 1e18;
        } else if (totalStakedByReferral < 300_000_000_000 * 1e18) {
            referralRewards[referrer] = 3_000 * 1e18;
        } else if (totalStakedByReferral < 600_000_000_000 * 1e18) {
            referralRewards[referrer] = 6_000 * 1e18;
        } else {
            referralRewards[referrer] = 0;
        }
    }

    function claimReferralRewards() public {
        require(referralsActivated, "Referrals not activated yet");
        require(!referralRewardClaimed[msg.sender], "Referral reward already claimed");

        calculateReferralRewards(msg.sender);
        uint256 reward = referralRewards[msg.sender];
        require(reward > 0, "No referral rewards to claim");

        referralRewardClaimed[msg.sender] = true;
        babyPerezoso.safeTransfer(msg.sender, reward);
        emit RewardPaid(msg.sender, reward);
    }


    function activateGetRewards() external onlyOwner {
        require(!getRewardsActivated, "Get rewards is already activated");
        getRewardsActivated = true;
    }

    function activateEscrow() external onlyOwner {
        require(!escrowActivated, "Escrow is already activated");
        escrowActivated = true;
    }

    function setReferrals(bool flag) external onlyOwner {
        referralsActivated = flag;
    }

    function setRewardEscrow(address _rewardEscrow) external onlyOwner {
        require(rewardEscrowAddress == address(0), "Reward escrow already set");
        rewardEscrowAddress = _rewardEscrow;
        rewardEscrow = RewardEscrow(_rewardEscrow);
    }

    function isOwner(Stake storage stake, address owner) internal view returns (bool) {
        for (uint256 i = 0; i < stake.owners.length; i++) {
            if (stake.owners[i] == owner) {
                return true;
            }
        }
        return false;
    }

    modifier onlyOwnerOrDeployer() {
        require(msg.sender == owner() || msg.sender == deployer, "Caller is not the owner or deployer");
        _;
    }
}
