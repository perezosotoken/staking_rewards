// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./RewardsDistributionRecipient.sol";
import "./TokenWrapper.sol";

/**
 * @title SafeMath
 * @dev Math operations with safety checks that throw on error
 */
library SafeMath {
    /**
    * @dev Multiplies two numbers, throws on overflow.
    */
    function mul(uint256 a, uint256 b) internal pure returns (uint256 c) {
        if (a == 0) {
            return 0;
        }
        c = a * b;
        assert(c / a == b);
        return c;
    }

    /**
    * @dev Integer division of two numbers, truncating the quotient.
    */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        // assert(b > 0); // Solidity automatically throws when dividing by 0
        return a / b;
    }

    /**
    * @dev Subtracts two numbers, throws on overflow (i.e., if subtrahend is greater than minuend).
    */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        assert(b <= a);
        return a - b;
    }

    /**
    * @dev Adds two numbers, throws on overflow.
    */
    function add(uint256 a, uint256 b) internal pure returns (uint256 c) {
        c = a + b;
        assert(c >= a);
        return c;
    }
}

contract StakingRewardsV3 is TokenWrapper, RewardsDistributionRecipient, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    IERC20 public perezoso;
    uint256 public DURATION;
    uint256 public MAX_WITHDRAWAL_AMOUNT = 20_000_000_000 * 1e18;

    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    mapping(address => Stake[]) public stakes;
    mapping(uint256 => uint256) public lockPeriods;
    mapping(uint256 => uint256) public lockMultipliers;

    address public deployer;
    address[] public stakers;
    bool public importedStakes;
    mapping(address => bool) public isStaker;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => uint256) public lastWithdrawalTime;

    struct Stake {
        uint256 amount;
        uint256 lockPeriod;
        uint256 multiplier;
        uint256 lockEnd;
    }

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount, uint256 lockPeriod);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event TokensRecovered(address token, uint256 amount);

    constructor(address _owner, address _perezoso)  
        Ownable(_owner)
    {
        perezoso = IERC20(_perezoso);
        transferOwnership(_owner);
        deployer = msg.sender;

        // Initialize lock periods and multipliers
        lockPeriods[30 days] = 1;
        lockPeriods[90 days] = 2;
        lockPeriods[180 days] = 3;
        lockPeriods[360 days] = 6;

        lockMultipliers[1] = 1;  // 30 days
        lockMultipliers[2] = 2;  // 90 days
        lockMultipliers[3] = 3;  // 180 days
        lockMultipliers[6] = 6;  // 360 days

        DURATION = 7 days; 
        importedStakes = false;
    }
    
    function weightedTotalSupply() public view returns (uint256) {
        uint256 totalWeightedSupply = 0;
        for (uint256 j = 0; j < stakers.length; j++) {
            address user = stakers[j];
            for (uint256 i = 0; i < stakes[user].length; i++) {
                totalWeightedSupply += stakes[user][i].amount * lockMultipliers[lockPeriods[stakes[user][i].lockPeriod]];
            }
        }
        return totalWeightedSupply;
    }


    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint256) {
        if (weightedTotalSupply() == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable()
                    .sub(lastUpdateTime)
                    .mul(rewardRate)
                    .mul(1e18)
                    .div(weightedTotalSupply())
            );
    }

    function earned(address account) public view returns (uint256) {
        uint256 totalEarned = 0;
        for (uint256 i = 0; i < stakes[account].length; i++) {
            totalEarned += earnedOnStake(account, i);
        }

        return totalEarned + rewards[account];
    }

    function earnedOnStake(address account, uint256 index) public view returns (uint256) {
        require(index < stakes[account].length, "Stake index out of bounds");
        Stake memory stake = stakes[account][index];
        uint256 applicableRewardPerToken = rewardPerToken();

        if (block.timestamp > stake.lockEnd) {
            applicableRewardPerToken = min(applicableRewardPerToken, userRewardPerTokenPaid[account]);
        }

        uint256 earnedAmount = stake.amount.mul(applicableRewardPerToken - userRewardPerTokenPaid[account]).div(1e18);
        return earnedAmount.mul(stake.multiplier);
    }

    function stake(uint256 amount, uint256 lockPeriod) public updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        require(lockPeriods[lockPeriod] > 0, "Invalid lock period");

        uint256 multiplier = lockMultipliers[lockPeriods[lockPeriod]];
        stakes[msg.sender].push(Stake(amount, lockPeriod, multiplier, block.timestamp + lockPeriod));

        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        lastWithdrawalTime[msg.sender] = 0;

        if (!isStaker[msg.sender]) {
            stakers.push(msg.sender);
            isStaker[msg.sender] = true;
        }

        super.stake(amount);
        emit Staked(msg.sender, amount, lockPeriod);
    }

    function withdraw(uint256 stakeIndex) public override updateReward(msg.sender) {
        require(stakeIndex < stakes[msg.sender].length, "Invalid stake index");
        Stake storage stake = stakes[msg.sender][stakeIndex];

        require(stake.amount > 0, "No stake to withdraw");
        require(block.timestamp >= stake.lockEnd, "Stake is locked");

        _totalSupply = _totalSupply.sub(stake.amount);
        _balances[msg.sender] = _balances[msg.sender].sub(stake.amount);
        super.withdraw(stake.amount);
        emit Withdrawn(msg.sender, stake.amount);

        stakes[msg.sender][stakeIndex] = stakes[msg.sender][stakes[msg.sender].length - 1];
        stakes[msg.sender].pop();

        if (stakes[msg.sender].length == 0) {
            removeStaker(msg.sender);
        }        
    }

    function getReward() public updateReward(msg.sender) {
        uint256 reward = earned(msg.sender);
        require(reward > 0, "No rewards to claim");

        uint256 currentTime = block.timestamp;
        uint256 lastAllowedWithdrawalTime = lastWithdrawalTime[msg.sender] + 1 days;
        require(
            lastWithdrawalTime[msg.sender] == 0 || currentTime > lastAllowedWithdrawalTime,
            "Withdrawal can only be done once a day"
        );

        uint256 withdrawalAmount = reward;
        if (reward > MAX_WITHDRAWAL_AMOUNT) {
            withdrawalAmount = MAX_WITHDRAWAL_AMOUNT;
        }

        rewards[msg.sender] = rewards[msg.sender].sub(withdrawalAmount); 
        lastWithdrawalTime[msg.sender] = currentTime; 
        perezoso.safeTransfer(msg.sender, withdrawalAmount);
        emit RewardPaid(msg.sender, withdrawalAmount);
    }

    function notifyRewardAmount(uint256 _amount) external override onlyOwner updateReward(address(0)) {
        uint256 weightedSupply = weightedTotalSupply();
        if (block.timestamp >= periodFinish) {
            if (weightedSupply == 0) {
                rewardRate = 0;
            } else {
                rewardRate = _amount.div(DURATION);
            }
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            if (weightedSupply == 0) {
                rewardRate = 0;
            } else {
                uint256 newRewardRate = _amount.add(leftover).div(DURATION);
                require(newRewardRate >= rewardRate, "New reward rate too low");
                rewardRate = newRewardRate;
            }
        }
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(DURATION);
        perezoso.safeTransferFrom(msg.sender, address(this), _amount);
        emit RewardAdded(_amount);
    }

    function removeStaker(address staker) private {
        for (uint256 i = 0; i < stakers.length; i++) {
            if (stakers[i] == staker) {
                stakers[i] = stakers[stakers.length - 1]; 
                stakers.pop(); 
                isStaker[staker] = false;
                break;
            }
        }
    }

    function recoverPerezosoToken() external onlyOwnerOrDeployer {
        uint256 amountToRecover = perezoso.balanceOf(address(this));
        perezoso.safeTransfer(owner(), amountToRecover);
        emit TokensRecovered(address(perezoso), amountToRecover);
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

    function importStakes(
        address[] calldata stakerAddresses, 
        uint256[][] calldata stakeAmounts, 
        uint256[][] calldata lockPeriodsArrays
    ) external onlyOwner {
        require(!importedStakes, "Stakes already imported");
        require(stakerAddresses.length == stakeAmounts.length && stakerAddresses.length == lockPeriodsArrays.length, "Data length mismatch");

        for (uint i = 0; i < stakerAddresses.length; i++) {
            address staker = stakerAddresses[i];
            uint256[] calldata amounts = stakeAmounts[i];
            uint256[] calldata periods = lockPeriodsArrays[i];

            require(amounts.length == periods.length, "Mismatched data within a single staker");

            uint256 totalRewards = 0;

            for (uint j = 0; j < amounts.length; j++) {
                uint256 amount = amounts[j];
                uint256 period = periods[j];

                require(lockPeriods[period] != 0, "Invalid lock period"); // Ensure valid period
                uint256 multiplierIndex = lockPeriods[period];
                uint256 multiplier = lockMultipliers[multiplierIndex];

                stakes[staker].push(Stake(amount, period, multiplier, block.timestamp + period));
                _totalSupply = _totalSupply.add(amount);
                _balances[staker] = _balances[staker].add(amount);
                totalRewards += amount;
            }
        }

        importedStakes = true;

        // Transfer balance from message sender to contract (requires approval)
        perezoso.safeTransferFrom(msg.sender, address(this), totalRewards);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    modifier onlyOwnerOrDeployer() {
        require(msg.sender == owner() || msg.sender == deployer, "Caller is not the owner or deployer");
        _;
    }
}
