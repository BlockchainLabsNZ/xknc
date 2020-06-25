usePlugin("@nomiclabs/buidler-waffle");
require("dotenv").config();

module.exports = {
  networks: {
    ropsten: {
      url: `https://ropsten.infura.io/v3/${process.env.INFURA_PROJECT_ID}`,
      accounts: [`0x${process.env.ROPSTEN_PRIVATE_KEY}`]
    }
  },
  solc: {
    version: "0.5.15"
  }
};
