pragma solidity 0.5.15;

contract IKyberStaking {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getLatestStakeBalance(address staker) external view returns(uint);
}