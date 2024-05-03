// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./RewardsDistributionRecipient.sol";

contract StakingRewards is RewardsDistributionRecipient, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    struct Tier {
        uint256 time;
        uint256 multiplier;
    }

    IERC20 public rewardsToken;
    IERC20 public stakingToken;
    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public rewardsDuration = 7 days;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public stakeTimes;
    mapping(address => Tier) public stakeTiers;
    mapping(uint256 => uint256) private _totalSupplyPerTier; // Tracks total supply per tier

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    Tier[] public tiers;

    constructor(
        address _rewardsToken,
        address _stakingToken
    ) Ownable(msg.sender) {
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);

        // Define time tiers and their multipliers
        tiers.push(Tier(30 days, 1));
        tiers.push(Tier(60 days, 2));
        tiers.push(Tier(90 days, 3));
        tiers.push(Tier(365 days, 6));
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        uint256 accumulatedReward = 0;
        for (uint i = 0; i < tiers.length; i++) {
            accumulatedReward += _totalSupplyPerTier[i] * tiers[i].multiplier;
        }
        return rewardPerTokenStored + (
            (lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18 / accumulatedReward
        );
    }

    function earned(address account) public view returns (uint256) {
        return _balances[account] * (rewardPerToken() - userRewardPerTokenPaid[account]) / 1e18 + rewards[account];
    }

    function getRewardForDuration() external view returns (uint256) {
        uint256 totalReward = 0;
        for (uint i = 0; i < tiers.length; i++) {
            totalReward += rewardRate * rewardsDuration * tiers[i].multiplier;
        }
        return totalReward;
    }

    function stake(uint256 amount, uint tierIndex) external nonReentrant whenNotPaused updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        require(tierIndex < tiers.length, "Invalid tier index");

        _totalSupply += amount;
        _balances[msg.sender] += amount;
        _totalSupplyPerTier[tierIndex] += amount;  // Update tier supply
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        stakeTimes[msg.sender] = block.timestamp;
        stakeTiers[msg.sender] = tiers[tierIndex];

        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        require(block.timestamp >= stakeTimes[msg.sender] + stakeTiers[msg.sender].time, "Stake is locked");

        _totalSupply -= amount;
        _balances[msg.sender] -= amount;
        _totalSupplyPerTier[tierIndex(stakeTiers[msg.sender])] -= amount;  // Update tier supply
        stakingToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    function notifyRewardAmount(uint256 reward) external override onlyOwner updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }

        uint balance = rewardsToken.balanceOf(address(this));
        require(rewardRate <= balance / rewardsDuration, "Provided reward too high");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(reward);
    }

    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAddress != address(stakingToken), "Cannot withdraw the staking token");
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        require(
            block.timestamp > periodFinish,
            "Previous rewards period must be complete before changing the duration for the new period"
        );
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    function tierIndex(Tier memory tier) private view returns (uint) {
        for (uint i = 0; i < tiers.length; i++) {
            if (tiers[i].time == tier.time && tiers[i].multiplier == tier.multiplier) {
                return i;
            }
        }
        revert("Tier not found");
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

    // EVENTS
    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
}
