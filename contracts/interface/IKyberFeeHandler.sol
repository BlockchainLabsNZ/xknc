pragma solidity 0.5.15;

contract IKyberFeeHandler {
    function claimStakerReward(
        address staker,
        uint256 epoch
    ) external returns(uint256 amountWei);
}