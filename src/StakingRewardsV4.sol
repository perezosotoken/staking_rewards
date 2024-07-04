// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./RewardsDistributionRecipient.sol";
import "./TokenWrapper.sol";
import "./SafeMath.sol";

contract StakingRewardsV4 is TokenWrapper, RewardsDistributionRecipient, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

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

    mapping(address => uint256) public referralCount;
    mapping(address => uint256) public referralStaked;
    mapping(address => address) public referredBy;
    mapping(address => RewardEscrow) public escrowedRewards;
    mapping(address => uint256) public referralRewards;

    address public deployer;
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

    struct RewardEscrow {
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
        lockMultipliers[3] = 3;
        lockMultipliers[6] = 6;
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

        if (block.timestamp <= stake.lockEnd) {
            return 0; // Earn 0 rewards if still within the lock period
        }

        uint256 applicableRewardPerToken = rewardPerToken();
        uint256 rewardDelta = applicableRewardPerToken.sub(userRewardPerTokenPaid[account]);

        uint256 newEarnedAmount = stake.amount.mul(rewardDelta).div(1e18).mul(stake.multiplier);

        return stake.totalEarned.add(newEarnedAmount);
    }

    function stakesCount(address user) public view returns (uint256) {
        return stakes[user].length;
    }

    function getAllStakes(address user) public view returns (Stake[] memory) {
        return stakes[user];
    }

    function stake(uint256 amount, uint256 lockPeriod) public updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        require(lockPeriods[lockPeriod] > 0, "Invalid lock period");

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
        require(lockPeriods[lockPeriod] > 0, "Invalid lock period");

        // Ensure the referrer is not the same as the staker and is a valid address
        require(referrer != msg.sender, "Referrer cannot be the staker");
        require(referrer != address(0), "Invalid referrer address");

        // Track referral data
        if (referredBy[msg.sender] == address(0)) {
            referredBy[msg.sender] = referrer;
            referralCount[referrer] = referralCount[referrer].add(1);
        }
        referralStaked[referrer] = referralStaked[referrer].add(amount);

        // Proceed with staking
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

    function notifyRewardAmount(uint256 _amount)
        external
        override
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
        require(escrowActivated, "Escrow not activated yet");
        require(getRewardsActivated, "Get rewards not activated yet");

        uint256 reward = earned(msg.sender);
        require(reward > 0, "No rewards to claim");

        RewardEscrow storage escrow = escrowedRewards[msg.sender];
        uint256 currentTime = block.timestamp;
        uint256 totalReleased = 0;

        if (escrow.releaseTime1 == 0) {
            escrow.totalEscrowed = reward;
            escrow.releaseTime1 = currentTime + 30 days;
            escrow.releaseTime2 = currentTime + 60 days;
            escrow.releaseTime3 = currentTime + 90 days;
            escrow.withdrawn1 = false;
            escrow.withdrawn2 = false;
            escrow.withdrawn3 = false;
        }

        if (currentTime >= escrow.releaseTime1 && !escrow.withdrawn1) {
            totalReleased = totalReleased.add(escrow.totalEscrowed.div(3));
            escrow.withdrawn1 = true;
        }
        if (currentTime >= escrow.releaseTime2 && !escrow.withdrawn2) {
            totalReleased = totalReleased.add(escrow.totalEscrowed.div(3));
            escrow.withdrawn2 = true;
        }
        if (currentTime >= escrow.releaseTime3 && !escrow.withdrawn3) {
            totalReleased = totalReleased.add(escrow.totalEscrowed.sub(escrow.totalEscrowed.div(3).mul(2))); // remaining amount
            escrow.withdrawn3 = true;
        }

        require(totalReleased > 0, "No rewards to release yet");

        rewards[msg.sender] = rewards[msg.sender].sub(totalReleased);
        rewardPaid[msg.sender] = rewardPaid[msg.sender].add(totalReleased);
        lastWithdrawalTime[msg.sender] = currentTime;
        babyPerezoso.safeTransfer(msg.sender, totalReleased); // Transfer reward tokens

        // Calculate and distribute referral rewards
        if (referralsActivated && referredBy[msg.sender] != address(0)) {
            calculateReferralRewards(referredBy[msg.sender]);
            uint256 referrerReward = referralRewards[referredBy[msg.sender]];
            if (referrerReward > 0) {
                babyPerezoso.safeTransfer(referredBy[msg.sender], referrerReward);
                emit RewardPaid(referredBy[msg.sender], referrerReward);
            }
        }

        emit RewardPaid(msg.sender, totalReleased);
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
                uint256 earnedAmount = earnedOnStake(account, i);
                stakes[account][i].totalEarned = earnedAmount;
            }
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function calculateReferralRewards(address referrer) internal {
        uint256 totalStakedByReferral = getTotalStakedByReferral(referrer);

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

    function activateGetRewards() external onlyOwner {
        require(!getRewardsActivated, "Get rewards is already activated");
        getRewardsActivated = true;
    }

    function activateEscrow() external onlyOwner {
        require(!escrowActivated, "Escrow is already activated");
        escrowActivated = true;
    }

    function activateReferrals() external onlyOwner {
        require(!referralsActivated, "Referrals are already activated");
        referralsActivated = true;
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
