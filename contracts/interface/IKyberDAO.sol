pragma solidity 0.5.15;

contract IKyberDAO {
    function vote(uint256 campaignID, uint256 option) external;
    function claimReward(address staker, uint256 epoch) external;
}