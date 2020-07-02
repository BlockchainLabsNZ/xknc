pragma solidity 0.5.15;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Detailed.sol";
import "@openzeppelin/contracts/lifecycle/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./util/Whitelist.sol";
import "./interface/IKyberNetworkProxy.sol";
import "./interface/IKyberStaking.sol";
import "./interface/IKyberDAO.sol";
import "./interface/IKyberFeeHandler.sol";

/*
* xKNC KyberDAO Pool Token
* Communal Staking Pool with Stated Governance Position
*/  
contract xKNC is ERC20, ERC20Detailed, Whitelist, Pausable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address private constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    IERC20 private knc;
    IKyberDAO private kyberDao;
    IKyberStaking private kyberStaking;
    IKyberNetworkProxy private kyberProxy;
    IKyberFeeHandler[] private kyberFeeHandlers;

    address[] private kyberFeeTokens;

    uint256 constant PERCENT = 100;
    uint256 constant MAX_UINT = 2**256 - 1;
    uint256 constant INITIAL_SUPPLY_MULTIPLIER = 10;

    uint256[] public feeDivisors;
    uint256 private withdrawableEthFees;
    uint256 private withdrawableKncFees;

    string public mandate;

    event MintWithEth(
        address indexed user,
        uint256 ethPayable,
        uint256 mintAmount,
        uint256 timestamp
    );
    event MintWithKnc(
        address indexed user,
        uint256 kncPayable,
        uint256 mintAmount,
        uint256 timestamp
    );
    event Burn(
        address indexed user,
        bool redeemedForKnc,
        uint256 burnAmount,
        uint256 timestamp
    );
    event FeeWithdraw(uint256 ethAmount, uint256 kncAmount, uint256 timestamp);
    event FeeDivisorsSet(uint256[] divisors);
    event EthRewardClaimed(uint256 amount, uint256 timestamp);
    event TokenRewardClaimed(uint256 amount, uint256 timestamp);

    enum FeeTypes {MINT, BURN, CLAIM}

    constructor(
        string memory _mandate,
        address _kyberStakingAddress,
        address _kyberProxyAddress,
        address _kyberTokenAddress,
        address _kyberDaoAddress
    ) public ERC20Detailed("xKNC", "xKNCa", 18) {
        mandate = _mandate;
        kyberStaking = IKyberStaking(_kyberStakingAddress);
        kyberProxy = IKyberNetworkProxy(_kyberProxyAddress);
        knc = IERC20(_kyberTokenAddress);
        kyberDao = IKyberDAO(_kyberDaoAddress);
    }

    /*
     * @notice Called by users buying with ETH
     * @dev Swaps ETH for KNC, deposits to Staking contract
     * @dev: Mints pro rata xKNC tokens
     * @param: kyberProxy.getExpectedRate(eth => knc)
     */
    function _mint(uint256 minRate) external payable whenNotPaused {
        require(msg.value > 0, "Must send eth with tx");
        uint256 fee = _administerEthFee(FeeTypes.MINT);

        uint256 ethValueForKnc = msg.value.sub(fee);
        uint256 kncBalanceBefore = getFundKncBalance();

        _swapEtherToToken(address(knc), ethValueForKnc, minRate);
        _deposit(getAvailableKncBalance());

        uint256 mintAmount = calculateMintAmount(kncBalanceBefore);

        emit MintWithEth(msg.sender, msg.value, mintAmount, block.timestamp);
        return super._mint(msg.sender, mintAmount);
    }

    /*
     * @notice Called by users buying with KNC
     * @notice Users must submit ERC20 approval before calling
     * @dev Deposits to Staking contract
     * @dev: Mints pro rata xKNC tokens
     * @param: Number of KNC to contribue
     */
    function _mintWithKnc(uint256 kncAmount) external whenNotPaused {
        require(kncAmount > 0, "Must contribute KNC");
        require(
            knc.transferFrom(msg.sender, address(this), kncAmount),
            "Insufficient balance/approval"
        );

        uint256 kncBalanceBefore = getFundKncBalance();
        _administerKncFee(kncAmount, FeeTypes.MINT);

        _deposit(getAvailableKncBalance());

        uint256 mintAmount = calculateMintAmount(kncBalanceBefore);

        emit MintWithKnc(msg.sender, kncAmount, mintAmount, block.timestamp);
        return super._mint(msg.sender, mintAmount);
    }

    /*
     * @notice Called by users burning their xKNC
     * @dev Calculates pro rata KNC and redeems from Staking contract
     * @dev: Exchanges for ETH if necessary and pays out to caller
     * @param tokensToRedeem
     * @param redeemForKnc bool: if true, redeem for KNC; otherwise ETH
     * @param kyberProxy.getExpectedRate(knc => eth)
     */
    function _burn(
        uint256 tokensToRedeem,
        bool redeemForKnc,
        uint256 minRate
    ) external nonReentrant {
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
            uint256 fee = _administerKncFee(proRataKnc, FeeTypes.BURN);
            knc.transfer(msg.sender, proRataKnc.sub(fee));
        } else {
            // safeguard to not overcompensate _burn sender in case eth was sent erringly to contract
            uint ethBalBefore = getFundEthBalance(); 
            kyberProxy.swapTokenToEther(
                ERC20(address(knc)),
                getAvailableKncBalance(),
                minRate
            );
            _administerEthFee(FeeTypes.BURN);

            uint valToSend = getFundEthBalance().sub(ethBalBefore);
            (bool success, ) = msg.sender.call.value(valToSend)("");
            require(success, "Rebate transfer failed");
        }

        emit Burn(msg.sender, redeemForKnc, tokensToRedeem, block.timestamp);
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
     * @param DAO campaign ID
     * @param Choice of voting option
     */
    function vote(uint256 campaignID, uint256 option) external onlyOwner {
        kyberDao.vote(campaignID, option);
    }

    /*
     * @notice Claim reward from previous epoch
     * @notice All fee handlers should be called at once
     * @dev Admin calls with relevant params
     * @dev ETH/other asset rewards swapped into KNC
     * @param epoch - KyberDAO epoch
     * @param feeHandlerIndices - indices of feeHandler contract to claim from
     * @param maxAmountsToSell - sellAmount above which slippage would be too high
     * and rewards would redirected into KNC in multiple trades
     * @param minRates - kyberProxy.getExpectedRate(eth/token => knc)
     */
    function claimReward(
        uint256 epoch,
        uint256[] calldata feeHandlerIndices,
        uint256[] calldata maxAmountsToSell,
        uint256[] calldata minRates
    ) external onlyOwner {
        require(
            feeHandlerIndices.length == maxAmountsToSell.length,
            "Arrays must be equal length"
        );
        require(
            maxAmountsToSell.length == minRates.length,
            "Arrays must be equal length"
        );

        for (uint256 i = 0; i < feeHandlerIndices.length; i++) {
            kyberFeeHandlers[i].claimStakerReward(address(this), epoch);

            if (kyberFeeTokens[i] == ETH_ADDRESS) {
                emit EthRewardClaimed(getFundEthBalance(), block.timestamp);
                _administerEthFee(FeeTypes.CLAIM);
            } else {
                uint256 tokenBal = IERC20(kyberFeeTokens[i]).balanceOf(
                    address(this)
                );
                emit TokenRewardClaimed(tokenBal, block.timestamp);
            }

            _unwindRewards(
                feeHandlerIndices[i],
                maxAmountsToSell[i],
                minRates[i]
            );
        }

        _deposit(getAvailableKncBalance());
    }

    /*
     * @notice Called when rewards size is too big for the one trade executed by `claimReward`
     * @param feeHandlerIndices - index of feeHandler previously claimed from
     * @param maxAmountsToSell - sellAmount above which slippage would be too high
     * and rewards would redirected into KNC in multiple trades
     * @param minRates - kyberProxy.getExpectedRate(eth/token => knc)
     */
    function unwindRewards(
        uint256[] calldata feeHandlerIndices,
        uint256[] calldata maxAmountsToSell,
        uint256[] calldata minRates
    ) external onlyOwner {
        for (uint256 i = 0; i < feeHandlerIndices.length; i++) {
            _unwindRewards(
                feeHandlerIndices[i],
                maxAmountsToSell[i],
                minRates[i]
            );
        }

        _deposit(getAvailableKncBalance());
    }

    /*
     * @notice Exchanges reward tokens (ETH, etc) for KNC
     */
    function _unwindRewards(
        uint256 feeHandlerIndex,
        uint256 maxAmountToSell,
        uint256 minRate
    ) private {
        address rewardTokenAddress = kyberFeeTokens[feeHandlerIndex];

        uint256 amountToSell;
        if (rewardTokenAddress == ETH_ADDRESS) {
            uint256 ethBal = getFundEthBalance();
            if (maxAmountToSell < ethBal) {
                amountToSell = maxAmountToSell;
            } else {
                amountToSell = ethBal;
            }

            _swapEtherToToken(address(knc), amountToSell, minRate);
        } else {
            uint256 tokenBal = IERC20(rewardTokenAddress).balanceOf(
                address(this)
            );
            if (maxAmountToSell < tokenBal) {
                amountToSell = maxAmountToSell;
            } else {
                amountToSell = tokenBal;
            }

            uint256 kncBalanceBefore = getAvailableKncBalance();

            _swapTokenToToken(
                rewardTokenAddress,
                amountToSell,
                address(knc),
                minRate
            );

            uint256 kncBalanceAfter = getAvailableKncBalance();
            _administerKncFee(
                kncBalanceAfter.sub(kncBalanceBefore),
                FeeTypes.CLAIM
            );
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
        return knc.balanceOf(address(this)).sub(withdrawableKncFees);
    }

    function _administerEthFee(FeeTypes _type) private returns (uint256 fee) {
        if (!isWhitelisted(msg.sender)) {
            uint256 feeRate = _getFeeRate(_type);
            if (feeRate == 0) return 0;

            fee = getFundEthBalance().div(feeRate);
            withdrawableEthFees = withdrawableEthFees.add(fee);
        }
    }

    function _administerKncFee(uint256 _kncAmount, FeeTypes _type)
        private
        returns (uint256 fee)
    {
        if (!isWhitelisted(msg.sender)) {
            uint256 feeRate = _getFeeRate(_type);
            if (feeRate == 0) return 0;

            fee = _kncAmount.div(feeRate);
            withdrawableKncFees = withdrawableKncFees.add(fee);
        }
    }

    function _getFeeRate(FeeTypes _type) private view returns (uint256) {
        if (_type == FeeTypes.MINT) return feeDivisors[0];
        if (_type == FeeTypes.BURN) return feeDivisors[1];
        if (_type == FeeTypes.CLAIM) return feeDivisors[2];
    }

    /*
     * @notice Called on initial deployment and on the addition of new fee handlers
     * @param Address of KyberFeeHandler contract
     * @param Address of underlying rewards token
     */
    function addKyberFeeHandler(
        address _kyberfeeHandlerAddress,
        address _tokenAddress
    ) external onlyOwner {
        kyberFeeHandlers.push(IKyberFeeHandler(_kyberfeeHandlerAddress));
        kyberFeeTokens.push(_tokenAddress);

        if (_tokenAddress != ETH_ADDRESS) {
            _approveKyberProxyContract(_tokenAddress, false);
        }
    }

    /* UTILS */

    /*
     * @notice Called by admin on deployment
     * @dev Approves Kyber Staking contract to deposit KNC
     * @param Pass _reset as true if resetting allowance to zero
     */
    function approveStakingContract(bool _reset) external onlyOwner {
        uint256 amount = _reset ? 0 : MAX_UINT;
        knc.approve(address(kyberStaking), amount);
    }

    /*
     * @notice Called by admin on deployment for KNC
     * @dev Approves Kyber Proxy contract to trade KNC
     * @param Token to approve on proxy contract
     * @param Pass _reset as true if resetting allowance to zero
     */
    function approveKyberProxyContract(address _token, bool _reset)
        external
        onlyOwner
    {
        _approveKyberProxyContract(_token, _reset);
    }

    function _approveKyberProxyContract(address _token, bool _reset) private {
        uint256 amount = _reset ? 0 : MAX_UINT;
        IERC20(_token).approve(address(kyberProxy), amount);
    }

    /*
     * @notice Called by admin on deployment
     * @dev (1 / feeDivisor) = % fee on mint, burn, ETH claims
     * @dev ex: A feeDivisor of 334 suggests a fee of 0.3%
     * @param feeDivisors[mint, burn, claim]:
     */
    function setFeeDivisors(uint256[] calldata _feeDivisors)
        external
        onlyOwner
    {
        require(
            _feeDivisors[0] >= 100 || _feeDivisors[0] == 0,
            "Mint fee must be zero or equal to or less than 1%"
        );
        require(
            _feeDivisors[1] >= 100,
            "Burn fee must be equal to or less than 1%"
        );
        require(_feeDivisors[2] >= 10, "Claim fee must be less than 10%");
        feeDivisors = _feeDivisors;

        emit FeeDivisorsSet(feeDivisors);
    }

    function withdrawFees() external onlyOwner {
        uint256 ethFees = withdrawableEthFees;
        uint256 kncFees = withdrawableKncFees;

        withdrawableEthFees = 0;
        withdrawableKncFees = 0;

        // address payable wallet = address(uint160(owner()));
        (bool success, ) = msg.sender.call.value(ethFees)("");
        require(success, "Rebate transfer failed");

        knc.transfer(owner(), kncFees);
        emit FeeWithdraw(ethFees, kncFees, block.timestamp);
    }

    /*
     * @notice Fallback to accommodate claimRewards function
     */
    function() external payable {}
}
