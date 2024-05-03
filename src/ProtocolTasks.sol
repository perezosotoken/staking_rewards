// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/KeeperCompatibleInterface.sol";

interface ICakePool {
     function notifyRewardAmount(uint256 reward) external ;
     function setRewardDistribution(address _rewardDistribution) external;
}

contract ProtocolTasks is KeeperCompatibleInterface {
    using SafeERC20 for IERC20;

    address public constant perezosoToken = 0x53ff62409b219ccaff01042bb2743211bb99882e 
    uint public interval = 604800; // 1 week
   
    address public perezoso_staking_contract = address(0);

    uint public perezoso_rewards_amount = 100000 ether; 

    ICakePool public perezosoStaking = ICakePool(perezoso_staking_contract);

    function doExecuteTasks() internal {

        // Other tasks here


        //notify reward amounts
        notifyRewardAmounts();
    }

    //Notify reward amounts
    function notifyRewardAmounts() internal {
        perezosoStaking.notifyRewardAmount(perezoso_rewards_amount);
    }

    //Called by Chainlink Keepers to check if work needs to be done
    function checkUpkeep(
        bytes calldata
    ) external view override returns (bool upkeepNeeded, bytes memory) {
        upkeepNeeded = true;
    }

    //Called by Chainlink Keepers to handle work
    function performUpkeep(bytes calldata) external override {
        doExecuteTasks();
    }

}