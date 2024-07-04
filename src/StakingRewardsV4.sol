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

    IERC20 public amphor;
    uint256 public DURATION = 7 days;
    uint256 public MAX_WITHDRAWAL_AMOUNT = 20_000_000_000 * 1e18;

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

    address public deployer;
    bool public importedStakes;
    bool public escrowActivated;
    bool public referralsActivated;

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

    constructor(address _owner, address _amphor)
        Ownable(_owner)
        TokenWrapper(_amphor)
    {
        amphor = IERC20(_amphor);
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

        uint256 applicableRewardPerToken = rewardPerToken();

        if (block.timestamp > stake.lockEnd) {
            applicableRewardPerToken = min(applicableRewardPerToken, userRewardPerTokenPaid[account]);
        }

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

        super.stake(amount);
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

        super.stake(amount);
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
        super.withdraw(stake.amount);
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

        amphor.safeTransferFrom(msg.sender, address(this), _amount);

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
    
    function getTotalStakedByReferral(address referrer) external view returns (uint256) {
        uint256 totalStaked = 0;
        for (uint256 i = 0; i < stakers.length; i++) {
            address staker = stakers[i];
            if (referredBy[staker] == referrer) {
                totalStaked = totalStaked.add(_balances[staker]);
            }
        }
        return totalStaked;
    }

    function getReward() public updateReward(msg.sender) {
        require(escrowActivated, "Escrow not activated yet");

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
        amphor.safeTransfer(msg.sender, totalReleased);
        emit RewardPaid(msg.sender, totalReleased);
    }

    function recoveramphorToken() external onlyOwnerOrDeployer {
        uint256 amountToRecover = amphor.balanceOf(address(this));
        amphor.safeTransfer(owner(), amountToRecover);
        emit TokensRecovered(address(amphor), amountToRecover);
    }

    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwnerOrDeployer {
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit TokensRecovered(tokenAddress, tokenAmount);
    }

    function setMaxWithdrawalAmount(uint256 amount) external onlyOwnerOrDeployer {
        MAX_WITHDRAWAL_AMOUNT = amount;
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
    
    function resetStakes() external onlyOwner {
        for (uint256 i = 0; i < stakers.length; i++) {
            address staker = stakers[i];
            delete stakes[staker];
            delete userRewardPerTokenPaid[staker];
            delete rewards[staker];
            delete _balances[staker];
            delete lastWithdrawalTime[staker];
            delete isStaker[staker];
            delete rewardPaid[staker];
            delete escrowedRewards[staker];
        }
        delete stakers;
        _totalSupply = 0;
        totalStakers = 0;
        rewardPerTokenStored = 0;
        lastUpdateTime = 0;
        rewardRate = 0;
        periodFinish = 0;
        importedStakes = false;
        escrowActivated = false;
    }

    function setRewardsData(
        address staker,
        uint256 newRewardPerTokenStored,
        uint256 newUserRewardPerTokenPaid
    ) external onlyOwner {
        rewardPerTokenStored = newRewardPerTokenStored;
        userRewardPerTokenPaid[staker] = newUserRewardPerTokenPaid;
    }

    function activateEscrow() external onlyOwner {
        require(!escrowActivated, "Escrow is already activated");
        escrowActivated = true;
    }

    function activateReferrals() external onlyOwner {
        require(!referralsActivated, "Referrals are already activated");
        referralsActivated = true;
    }

    function importStakes(
        address[] calldata stakerAddresses,
        uint256[][] calldata stakeAmounts,
        uint256[][] calldata lockPeriodsArrays,
        uint256[][] calldata totalEarnedPerStakeArrays,
        uint256[] calldata totalRewardPaidPerStaker,
        uint256 rewardPerTokenStored_,
        uint256 lastUpdateTime_,
        string[][] calldata stakeTimes
    ) external onlyOwner {
        require(
            stakerAddresses.length == stakeAmounts.length &&
            stakerAddresses.length == lockPeriodsArrays.length &&
            stakerAddresses.length == totalEarnedPerStakeArrays.length &&
            stakerAddresses.length == totalRewardPaidPerStaker.length &&
            stakerAddresses.length == stakeTimes.length,
            "Data length mismatch"
        );

        rewardPerTokenStored = rewardPerTokenStored_;
        lastUpdateTime = lastUpdateTime_;

        uint256 totalStaked = 0;

        for (uint256 i = 0; i < stakerAddresses.length; i++) {
            totalStaked = totalStaked.add(_importStakerStakes(
                stakerAddresses[i],
                stakeAmounts[i],
                lockPeriodsArrays[i],
                totalEarnedPerStakeArrays[i],
                totalRewardPaidPerStaker[i],
                rewardPerTokenStored_,
                stakeTimes[i]
            ));
        }

        amphor.safeTransferFrom(msg.sender, address(this), totalStaked);
        importedStakes = true;
    }

    function _importStakerStakes(
        address staker,
        uint256[] calldata amounts,
        uint256[] calldata periods,
        uint256[] calldata earnings,
        uint256 rewardPaidAmount,
        uint256 rewardPerTokenStored_,
        string[] calldata times
    ) private returns (uint256 totalStaked) {
        require(
            amounts.length == periods.length &&
            amounts.length == earnings.length &&
            amounts.length == times.length,
            "Mismatched data within a single staker"
        );

        rewardPaid[staker] = rewardPaidAmount;
        userRewardPerTokenPaid[staker] = rewardPerTokenStored_;

        for (uint256 j = 0; j < amounts.length; j++) {
            require(lockPeriods[periods[j]] != 0, "Invalid lock period");

            address[] memory ownersList = new address[](1);
            ownersList[0] = staker;

            uint256 multiplier = lockMultipliers[lockPeriods[periods[j]]];
            stakes[staker].push(Stake(amounts[j], periods[j], multiplier, block.timestamp + periods[j], earnings[j], ownersList));
            _totalSupply = _totalSupply.add(amounts[j]);
            _balances[staker] = _balances[staker].add(amounts[j]);
            totalStaked = totalStaked.add(amounts[j]);
        }

        if (!isStaker[staker]) {
            stakers.push(staker);
            isStaker[staker] = true;
            totalStakers = totalStakers.add(1);
        }
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
