pragma solidity ^0.5.15;

/* Adapted from OpenZeppelin */
contract Pausable {
    /**
     * @dev Emitted when the pause is triggered by a pauser.
     */
    event Paused();

    /**
     * @dev Emitted when the pause is lifted by a pauser.
     */
    event Unpaused();

    bool private _paused;
    address public pauser;

    /**
     * @dev Initializes the contract in unpaused state. Assigns the Pauser role
     * to the deployer.
     */
    constructor () internal {
        _paused = false;
        pauser = msg.sender;
    }

    /**
     * @dev Returns true if the contract is paused, and false otherwise.
     */
    function paused() public view returns (bool) {
        return _paused;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is not paused.
     */
    modifier whenNotPaused() {
        require(!_paused, "Pausable: paused");
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is paused.
     */
    modifier whenPaused() {
        require(_paused, "Pausable: not paused");
        _;
    }

    /**
     * @dev Called by a pauser to pause, triggers stopped state.
     */
    function pause() public onlyPauser whenNotPaused {
        _paused = true;
        emit Paused();
    }

    /**
     * @dev Called by a pauser to unpause, returns to normal state.
     */
    function unpause() public onlyPauser whenPaused {
        _paused = false;
        emit Unpaused();
    }

    modifier onlyPauser {
        require(msg.sender == pauser, "Don't have rights");
        _;
    }
}
