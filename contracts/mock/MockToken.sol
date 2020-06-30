pragma solidity 0.5.15;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() public {
        _mint(msg.sender, 1000e18);
    }
    
}