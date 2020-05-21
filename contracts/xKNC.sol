pragma solidity 0.5.15;

import "./token/ERC20.sol";
import "./util/Whitelist.sol";
import "./util/SafeMath.sol";
import "./util/Pausable.sol";
import "./interface/IKyberNetworkProxy.sol";
import "./interface/IKyberStaking.sol";
import "./interface/IKyberDAO.sol";


contract xKNC is ERC20, Whitelist, Pausable {
    using SafeMath for uint256;

    address private constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address private kyberTokenAddress;

    IERC20 private kyberToken;
    IKyberDAO private kyberDao;
    IKyberStaking private kyberStaking;
    IKyberNetworkProxy private kyberProxy;

    uint256 constant INITIAL_SUPPLY_MULTIPLIER = 10;
    uint256 constant MAX_UINT = 2**256 - 1;

    uint256 private feeDivisor;
    uint256 private withdrawableEthFees;
    uint256 private withdrawableKncFees;
    uint256 private accruedEthFees;
    uint256 private accruedKncFees;

    string public mandate;

    constructor(string memory _mandate) public ERC20("xKNC", "xKNCa") {
        mandate = _mandate;
    }

    /*
     * @notice Called by users buying with ETH
     * @dev Swaps ETH for KNC, deposits to Staking contract
     * @dev: Mints pro rata xKNC tokens
     */
    function _mint() external payable whenNotPaused {
        require(msg.value > 0, "Must send eth with tx");
        _administerEthFee(msg.value);

        uint256 ethValueForKnc = getFundEthBalance();
        uint256 kncBalanceBefore = getFundKncBalance();

        (, uint256 slippageRate) = kyberProxy.getExpectedRate(
            ERC20(ETH_ADDRESS),
            ERC20(kyberTokenAddress),
            ethValueForKnc
        );
        kyberProxy.swapEtherToToken.value(ethValueForKnc)(
            ERC20(kyberTokenAddress),
            slippageRate
        );
        _deposit(getAvailableKncBalance());

        uint256 mintAmount = calculateMintAmount(kncBalanceBefore);
        return super._mint(msg.sender, mintAmount);
    }

    /*
     * @notice Called by users buying with KNC
     * @notice Users must submit ERC20 approval before calling
     * @dev Deposits to Staking contract
     * @dev: Mints pro rata xKNC tokens
     */
    function _mintWithKnc(uint256 kncAmount) external whenNotPaused {
        require(kncAmount > 0, "Must contribute KNC");
        require(
            kyberToken.transferFrom(msg.sender, address(this), kncAmount),
            "Insufficient balance/approval"
        );

        uint256 kncBalanceBefore = getFundKncBalance();
        _administerKncFee(kncAmount);

        _deposit(getAvailableKncBalance());

        uint256 mintAmount = calculateMintAmount(kncBalanceBefore);
        return super._mint(msg.sender, mintAmount);
    }

    /*
     * @notice Called by users burning their xKNC
     * @param tokensToRedeem
     * @param redeemForKnc bool: if true, redeem for KNC; otherwise ETH
     * @dev Calculates pro rata KNC and redeems from Staking contract
     * @dev: Exchanges for ETH if necessary and pays out to caller
     */
    function _burn(uint256 tokensToRedeem, bool redeemForKnc)
        external
        whenNotPaused
    {
        require(
            balanceOf(msg.sender) >= tokensToRedeem,
            "Insufficient balance"
        );

        uint256 proRataKnc = getFundKncBalance().mul(tokensToRedeem).div(
            totalSupply()
        );
        _withdraw(proRataKnc);
        super._burn(msg.sender, tokensToRedeem);

        uint256 fee;
        if (redeemForKnc) {
            fee = _administerKncFee(proRataKnc);
            kyberToken.transfer(msg.sender, proRataKnc.sub(fee));
        } else {
            (, uint256 slippageRate) = kyberProxy.getExpectedRate(
                ERC20(kyberTokenAddress),
                ERC20(ETH_ADDRESS),
                proRataKnc
            );
            kyberProxy.swapTokenToEther(
                ERC20(kyberTokenAddress),
                getAvailableKncBalance(),
                slippageRate
            );
            _administerEthFee(getFundEthBalance());
            msg.sender.transfer(getFundEthBalance());
        }
    }

    /*
     * @notice Calculates proportional issuance 
        according to KNC contribution
     */
    function calculateMintAmount(uint256 kncBalanceBefore)
        internal
        view
        returns (uint256 mintAmount)
    {
        uint256 kncBalanceAfter = getFundKncBalance();
        if (totalSupply() == 0)
            return kncBalanceAfter.mul(INITIAL_SUPPLY_MULTIPLIER);

        mintAmount = (kncBalanceAfter.sub(kncBalanceBefore))
            .mul(totalSupply())
            .div(kncBalanceBefore);
    }

    /*
     * @notice KyberDAO deposit
     */
    function _deposit(uint256 amount) private {
        kyberStaking.deposit(amount);
    }

    /*
     * @notice KyberDAO withdraw
     */
    function _withdraw(uint256 amount) private {
        kyberStaking.withdraw(amount);
    }

    /*
     * @notice Vote on KyberDAO campaigns
     * @dev Admin calls with relevant params for each campaign in an epoch
     */
    function vote(uint256 campaignID, uint256 option) external onlyOwner {
        kyberDao.vote(campaignID, option);
    }

    /*
     * @notice Claim reward from previous epoch
     * @dev Admin calls with relevant params
     * @dev ETH rewards swapped into KNC
     */
    function claimReward(address staker, uint256 epoch) external onlyOwner {
        kyberDao.claimReward(staker, epoch);
        _administerEthFee(getFundEthBalance());
        uint256 ethToSwap = getFundEthBalance();

        (, uint256 slippageRate) = kyberProxy.getExpectedRate(
            ERC20(ETH_ADDRESS),
            ERC20(kyberTokenAddress),
            ethToSwap
        );
        kyberProxy.swapEtherToToken.value(ethToSwap)(
            ERC20(kyberTokenAddress),
            slippageRate
        );
    }

    /*
     * @notice Returns ETH balance belonging to the fund
     */
    function getFundEthBalance() public view returns (uint256) {
        return address(this).balance.sub(withdrawableEthFees);
    }

    /*
     * @notice Returns KNC balance staked to DAO
     */
    function getFundKncBalance() public view returns (uint256) {
        return kyberStaking.getLatestStakeBalance(address(this));
    }

    /*
     * @notice Returns KNC balance available to stake
     */
    function getAvailableKncBalance() public view returns (uint256) {
        return kyberToken.balanceOf(address(this)).sub(withdrawableKncFees);
    }

    function _administerEthFee(uint256 ethValue) private returns (uint256 fee) {
        if (!isWhitelisted(msg.sender)) {
            fee = ethValue.div(feeDivisor);
            withdrawableEthFees = withdrawableEthFees.add(fee);
        }
    }

    function _administerKncFee(uint256 kncAmount)
        private
        returns (uint256 fee)
    {
        if (!isWhitelisted(msg.sender)) {
            fee = kncAmount.div(feeDivisor);
            withdrawableKncFees = withdrawableKncFees.add(fee);
        }
    }

    /* ADDRESS SETTERS */

    function setKyberTokenAddress(address _kyberTokenAddress)
        external
        onlyOwner
    {
        kyberTokenAddress = _kyberTokenAddress;
        kyberToken = IERC20(_kyberTokenAddress);
    }

    function setKyberProxyAddress(address _kyberProxyAddress)
        external
        onlyOwner
    {
        kyberProxy = IKyberNetworkProxy(_kyberProxyAddress);
    }

    function setKyberStakingAddress(address _kyberStakingAddress)
        external
        onlyOwner
    {
        kyberStaking = IKyberStaking(_kyberStakingAddress);
    }

    function setKyberDaoAddress(address _kyberDaoAddress) external onlyOwner {
        kyberDao = IKyberDAO(_kyberDaoAddress);
    }

    /* UTILS */

    /*
     * @notice Called by admin on deployment
     * @dev Approves Kyber Staking contract to deposit KNC
     */
    function approveStakingContract() external onlyOwner {
        kyberToken.approve(address(kyberStaking), MAX_UINT);
    }

    /*
     * @notice Called by admin on deployment
     * @dev Approves Kyber Proxy contract to trade KNC
     */
    function approveKyberProxyContract() external onlyOwner {
        kyberToken.approve(address(kyberProxy), MAX_UINT);
    }

    /*
     * @notice Called by admin on deployment
     * @param feeDivisor: (1 / feeDivisor) = % fee on mint, burn, ETH claims
     * @dev ex: A feeDivisor of 334 suggests a fee of 0.3%
     */
    function setFeeDivisor(uint256 _feeDivisor) external onlyOwner {
        feeDivisor = _feeDivisor;
    }

    function withdrawFees() external onlyOwner {
        uint256 ethFees = withdrawableEthFees;
        uint256 kncFees = withdrawableKncFees;
        withdrawableEthFees = 0;
        withdrawableKncFees = 0;
        accruedEthFees = accruedEthFees.add(ethFees);
        accruedKncFees = accruedKncFees.add(kncFees);
        address payable wallet = address(uint160(owner()));
        wallet.transfer(ethFees);
        kyberToken.transfer(owner(), kncFees);
    }

    /*
     * @notice Fallback to accommodate claimRewards function
     */
    function() external payable {}
}
