
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

  const KYBER_PROXY_ADDRESS = "0x41E5f8bC2a6D0235F844a6F7CcD0751E187A8416";
  const KYBER_TOKEN_ADDRESS = "0x7B2810576aa1cce68F2B118CeF1F36467c648F92";
  const KYBER_STAKING_ADDRESS = "0xE6c9Ad0A4e1fbf6A953F448a9415fb24E546d5D7";
  const KYBER_DAO_ADDRESS = "0x117971296b17A524411022353b2b7f9A132D3166";


  await xknc.setFeeDivisor("250");
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