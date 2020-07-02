pragma solidity 0.5.15;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockKyberFeeHandler {

    function claimStakerReward(address _address, uint _epoch) external returns(uint ethBal) {
        ethBal = address(this).balance;
        msg.sender.call.value(ethBal);
    }

    function() external payable {

    }
}