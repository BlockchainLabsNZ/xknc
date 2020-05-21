<img src="./xknc.png" class="logo">

# xKNC: KyberDAO Pool Token
Investors buy the liquid xKNC token to  participate in Kyber staking rewards and governance without active management requirements.

## To deploy to Ropsten
- Clone this repo
- `npm install`
- Fill your `.env` file according to the example
- Run `npx buidler run scripts/deploy.js --network ropsten`
- Manually run `approveStakingContract` on Etherscan/Web3 Interface (Buidler deployment script doesn't run it properly)
- Manually run `approveKyberProxyContract` on Etherscan/Web3 Interface (Buidler deployment script doesn't run it properly)

## To flatten contract
- Run `truffle-flattener contracts/xKNC.sol`


<style>
    .logo {
        margin: 10px 0px;
        width: 120px;
        height: auto;
    }

</style>
