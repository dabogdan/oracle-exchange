import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-foundry";
import "@layerzerolabs/hardhat-deploy";
import "@layerzerolabs/hardhat-tron";
import "@openzeppelin/hardhat-upgrades";
import * as dotenv from "dotenv";

dotenv.config();

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      { version: "0.8.13" },
      { version: "0.8.20" },
      { version: "0.8.23" },
    ],
  },

  tronSolc: {
    enable: true,
    filter: [],
    compilers: [
      { version: "0.8.13" },
      { version: "0.8.20" },
      { version: "0.8.23" },
    ],
    versionRemapping: [
      ["0.8.28", "0.8.23"],
      ["0.8.22", "0.8.23"],
      ["0.8.13", "0.8.13"],
    ],
  },

  namedAccounts: {
    deployer: {
      default: 0,
    },
  },

  typechain: {
    outDir: "types",
    target: "ethers-v6",
  },

  networks: {
    tron_docker: {
      url: "http://127.0.0.1:9090/jsonrpc",
      accounts: [
        "0000000000000000000000000000000000000000000000000000000000000001",
      ],
      tron: true,
    },
  },
};

export default config;