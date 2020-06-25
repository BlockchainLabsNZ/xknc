
// ropsten
async function main() {
  const [deployer] = await ethers.getSigners();

  console.log(
    "Deploying contracts with the account:",
    await deployer.getAddress()
  );
  
  console.log("Account balance:", (await deployer.getBalance()).toString());

  const xKNC = await ethers.getContractFactory("xKNC");
  const xknc = await xKNC.deploy("xKNC Mandate: Stakers");

  await xknc.deployed();

  console.log("xKNC address:", xknc.address);

  const KYBER_PROXY_ADDRESS = "0xa16Fc6e9b5D359797999adA576F7f4a4d57E8F75";
  const KYBER_TOKEN_ADDRESS = "0x7B2810576aa1cce68F2B118CeF1F36467c648F92";
  const KYBER_STAKING_ADDRESS = "0xDca0cB013EC92163fbbeb9A4962CBA31723a3515";
  const KYBER_DAO_ADDRESS = "0x98fac5AD613c707Ef3434B609A945986e4d05d07";

  const KYBER_FEE_HANDLER_ETH = "0xe57B2c3b4E44730805358131a6Fc244C57178Da7"
  const ETH_ADDRESS = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"

  await xknc.addKyberFeeHandlerAddress(KYBER_FEE_HANDLER_ETH, ETH_ADDRESS);  

  await xknc.setFeeDivisor("500");
  console.log('fee divisor set')
  await xknc.setKyberProxyAddress(KYBER_PROXY_ADDRESS);
  console.log('kyber proxy set')
  await xknc.setKyberTokenAddress(KYBER_TOKEN_ADDRESS);
  console.log('kyber token set')
  await xknc.setKyberStakingAddress(KYBER_STAKING_ADDRESS);
  console.log('kyber staking set')
  await xknc.setKyberDaoAddress(KYBER_DAO_ADDRESS);
  console.log('kyber dao set')
  // await xknc.approveStakingContract();
  console.log('****Make sure you manually run `approveStakingContract`****')
  // await xknc.approveKyberProxyContract();
  console.log("****Make sure you manually run `approveKyberProxyContract`****");
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });