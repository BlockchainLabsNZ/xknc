pragma solidity 0.5.15;

contract MockKyberFeeHandler {
    function claimStakerReward(address _address, uint _epoch) external returns(uint ethBal) {
        ethBal = address(this).balance;
        msg.sender.transfer(ethBal);
    }

    function() external payable {

    }
}