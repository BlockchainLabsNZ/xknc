pragma solidity 0.5.15;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Detailed.sol";
import "@openzeppelin/contracts/lifecycle/Pausable.sol";

import "./util/Whitelist.sol";
import "./interface/IKyberNetworkProxy.sol";
import "./interface/IKyberStaking.sol";
import "./interface/IKyberDAO.sol";
import "./interface/IKyberFeeHandler.sol";


contract xKNC is ERC20, ERC20Detailed, Whitelist, Pausable {
    using SafeMath for uint256;

    address private constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address private kyberTokenAddress;

    IERC20 private kyberToken;
    IKyberDAO private kyberDao;
    IKyberStaking private kyberStaking;
    IKyberNetworkProxy private kyberProxy;
    IKyberFeeHandler[] private kyberFeeHandlers;

    address[] private kyberFeeTokens;

    uint256 constant PERCENT = 100;
    uint256 constant MAX_UINT = 2**256 - 1;
    uint256 constant INITIAL_SUPPLY_MULTIPLIER = 10;

    uint256 private feeDivisor;
    uint256 private withdrawableEthFees;
    uint256 private withdrawableKncFees;
    uint256 private accruedEthFees;
    uint256 private accruedKncFees;

    string public mandate;

    constructor(string memory _mandate)
        public
        ERC20Detailed("xKNC", "xKNCa", 18)
    {
        mandate = _mandate;
    }

    /*
     * @notice Called by users buying with ETH
     * @dev Swaps ETH for KNC, deposits to Staking contract
     * @dev: Mints pro rata xKNC tokens
     */
    function _mint() external payable whenNotPaused {
        require(msg.value > 0, "Must send eth with tx");
        _administerEthFee();

        uint256 ethValueForKnc = getFundEthBalance();
        uint256 kncBalanceBefore = getFundKncBalance();

        uint256 slippageRate = _getMinExpectedRate(
            ETH_ADDRESS,
            kyberTokenAddress,
            ethValueForKnc
        );
        _swapEtherToToken(kyberTokenAddress, ethValueForKnc, slippageRate);
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

        if (redeemForKnc) {
            uint256 fee = _administerKncFee(proRataKnc);
            kyberToken.transfer(msg.sender, proRataKnc.sub(fee));
        } else {
            uint256 slippageRate = _getMinExpectedRate(
                kyberTokenAddress,
                ETH_ADDRESS,
                proRataKnc
            );
            kyberProxy.swapTokenToEther(
                ERC20(kyberTokenAddress),
                getAvailableKncBalance(),
                slippageRate
            );
            _administerEthFee();
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
     * @dev ETH/other asset rewards swapped into KNC
     * @param epoch - KyberDAO epoch
     * @param feeHandlerIndices - indices of feeHandler contract to claim from
     * @param sellSharePercents - pct out of 100 of fees to sell (less than 100 if order would be too large)
     */
    function claimReward(
        uint256 epoch,
        uint256[] calldata feeHandlerIndices,
        uint256[] calldata sellSharePercents
    ) external onlyOwner {
        require(
            feeHandlerIndices.length == sellSharePercents.length,
            "Arrays must be equal length"
        );
        for (uint256 i = 0; i < feeHandlerIndices.length; i++) {
            kyberFeeHandlers[i].claimStakerReward(address(this), epoch);

            if (feeHandlerIndices[i] == 0) {
                _administerEthFee();
            }

            _unwindRewards(feeHandlerIndices[i], sellSharePercents[i]);
        }

        _deposit(getAvailableKncBalance());
    }

    /*
     * @notice Called when rewards size is too big for the one trade executed by `claimReward`
     * @param feeHandlerIndices - index of feeHandler previously claimed from
     * @param sellSharePercents - pct out of 100 of fees to sell (less than 100 if order would be too large)
     */
    function unwindRewards(
        uint256[] calldata feeHandlerIndices,
        uint256[] calldata sellSharePercents
    ) external onlyOwner {
        for (uint256 i = 0; i < feeHandlerIndices.length; i++) {
            _unwindRewards(feeHandlerIndices[i], sellSharePercents[i]);
        }

        _deposit(getAvailableKncBalance());
    }

    /*
     * @notice Exchanges reward tokens (ETH, etc) for KNC
     */
    function _unwindRewards(uint256 feeHandlerIndex, uint256 sellSharePercent)
        private
    {
        address rewardTokenAddress = kyberFeeTokens[feeHandlerIndex];

        uint256 sellShareAmount;
        uint256 slippageRate;

        if (feeHandlerIndex == 0) {
            uint256 ethBal = getFundEthBalance();
            sellShareAmount = ethBal.mul(sellSharePercent).div(PERCENT);

            slippageRate = _getMinExpectedRate(
                rewardTokenAddress,
                kyberTokenAddress,
                sellShareAmount
            );
            _swapEtherToToken(kyberTokenAddress, sellShareAmount, slippageRate);
        } else {
            uint256 tokenBal = IERC20(rewardTokenAddress).balanceOf(
                address(this)
            );
            sellShareAmount = tokenBal.mul(sellSharePercent).div(PERCENT);

            slippageRate = _getMinExpectedRate(
                rewardTokenAddress,
                kyberTokenAddress,
                sellShareAmount
            );

            uint256 kncBalanceBefore = getAvailableKncBalance();
            _swapTokenToToken(
                rewardTokenAddress,
                sellShareAmount,
                kyberTokenAddress,
                slippageRate
            );

            uint256 kncBalanceAfter = getAvailableKncBalance();
            _administerKncFee(kncBalanceAfter.sub(kncBalanceBefore));
        }
    }

    function _swapEtherToToken(
        address toAddress,
        uint256 amount,
        uint256 minRate
    ) private {
        kyberProxy.swapEtherToToken.value(amount)(ERC20(toAddress), minRate);
    }

    function _swapTokenToToken(
        address fromAddress,
        uint256 amount,
        address toAddress,
        uint256 minRate
    ) private {
        kyberProxy.swapTokenToToken(
            ERC20(fromAddress),
            amount,
            ERC20(toAddress),
            minRate
        );
    }

    function _getMinExpectedRate(
        address fromAddress,
        address toAddress,
        uint256 amount
    ) private view returns (uint256 minRate) {
        (, minRate) = kyberProxy.getExpectedRate(
            ERC20(fromAddress),
            ERC20(toAddress),
            amount
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

    function _administerEthFee() private returns (uint256 fee) {
        if (!isWhitelisted(msg.sender)) {
            fee = getFundEthBalance().div(feeDivisor);
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

    // called on initial deployment and on the addition of new fee handlers
    function addKyberFeeHandlerAddress(
        address _kyberfeeHandlerAddress,
        address _tokenAddress
    ) external onlyOwner {
        kyberFeeHandlers.push(IKyberFeeHandler(_kyberfeeHandlerAddress));
        kyberFeeTokens.push(_tokenAddress);
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
