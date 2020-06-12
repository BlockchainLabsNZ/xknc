pragma solidity 0.5.15;


contract MockKyberDAO {
    function vote(uint campaignID, uint option) external {
        // 
    }

    function claimReward(address staker, uint epoch) external {
        // 
        msg.sender.transfer(1e16);
    }

    function() external payable {

    }
}