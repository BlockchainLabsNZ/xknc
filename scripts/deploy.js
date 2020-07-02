// ropsten
const KYBER_PROXY_ADDRESS = '0xd719c34261e099Fdb33030ac8909d5788D3039C4'
const KYBER_TOKEN_ADDRESS = '0x7B2810576aa1cce68F2B118CeF1F36467c648F92'
const KYBER_STAKING_ADDRESS = '0x9A73c6217cd595bc449bA6fEF6efF53f29014f42'
const KYBER_DAO_ADDRESS = '0x2Be7dC494362e4FCa2c228522047663B17aE17F9'

const KYBER_FEE_HANDLER_ETH = '0xfF456D9A8cbB5352eF77dEc2337bAC8dEC63bEAC' 
const ETH_ADDRESS = '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE'

async function main() {
  const [deployer] = await ethers.getSigners()

  console.log(
    'Deploying contracts with the account:',
    await deployer.getAddress(),
  )

  console.log('Account balance:', (await deployer.getBalance()).toString())

  const xKNC = await ethers.getContractFactory('xKNC')
  const xknc = await xKNC.deploy(
    'xKNC Mandate: Stakers',
    KYBER_STAKING_ADDRESS,
    KYBER_PROXY_ADDRESS,
    KYBER_TOKEN_ADDRESS,
    KYBER_DAO_ADDRESS
  )

  await xknc.deployed()
  console.log('xKNC address:', xknc.address)

  await xknc.addKyberFeeHandler(KYBER_FEE_HANDLER_ETH, ETH_ADDRESS)
  console.log('ETH fee handler added')

  await xknc.setFeeDivisors(['0', '500', '50'])
  console.log('fee divisor set')
  await xknc.approveStakingContract(false);
  console.log('kyber staking contract approved')
  await xknc.approveKyberProxyContract(KYBER_TOKEN_ADDRESS, false);
  console.log('knc approved on proxy contract')
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
