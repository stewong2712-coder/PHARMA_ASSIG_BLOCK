// Deploys RxGuard to the local Hardhat network (or any network you pass with --network).
const hre = require("hardhat");

async function main() {
  const [admin] = await hre.ethers.getSigners();
  const g = await (await hre.ethers.getContractFactory("RxGuard")).deploy(admin.address);
  await g.waitForDeployment();
  console.log("RxGuard deployed at", await g.getAddress(), "administrator", admin.address);
}
main().catch((e) => { console.error(e); process.exit(1); });
