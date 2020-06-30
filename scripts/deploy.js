// ropsten
// const KYBER_PROXY_ADDRESS = '0xd719c34261e099Fdb33030ac8909d5788D3039C4' // katalyst
const KYBER_PROXY_ADDRESS = '0x818E6FECD516Ecc3849DAf6845e3EC868087B755'
const KYBER_TOKEN_ADDRESS = '0x7B2810576aa1cce68F2B118CeF1F36467c648F92'
const KYBER_STAKING_ADDRESS = '0xDca0cB013EC92163fbbeb9A4962CBA31723a3515'
const KYBER_DAO_ADDRESS = '0x98fac5AD613c707Ef3434B609A945986e4d05d07'

const KYBER_FEE_HANDLER_ETH = '0xfF456D9A8cbB5352eF77dEc2337bAC8dEC63bEAC' // katalyst
// const KYBER_FEE_HANDLER_ETH = '0xe57B2c3b4E44730805358131a6Fc244C57178Da7'
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
  )

  await xknc.deployed()
  console.log('xKNC address:', xknc.address)

  await xknc.addKyberFeeHandler(KYBER_FEE_HANDLER_ETH, ETH_ADDRESS)
  console.log('ETH fee handler added')

  await xknc.setFeeDivisors(['0', '500', '50'])
  console.log('fee divisor set')
  await xknc.setKyberDaoAddress(KYBER_DAO_ADDRESS)
  console.log('kyber dao set')
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
