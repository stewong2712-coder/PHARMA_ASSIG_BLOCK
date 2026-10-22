/**
 * Deploys RxGuard to a live network (Sepolia) and prepares the public demo.
 *
 *   npx hardhat run scripts/deploy-live.js --network sepolia
 *
 * What it does:
 *   1. Checks your wallet has enough test ETH for everything below.
 *   2. Deploys the contract. Your MetaMask account becomes the administrator.
 *   3. Creates five DEMO wallets (regulator, manufacturer, wholesaler, pharmacy,
 *      prescriber), sends each a little test ETH and grants roles.
 *   4. Runs a short story on the real chain: a lot of 2,000 tablets is made,
 *      400 reach a pharmacy under a regulator quota, a two-fill prescription
 *      is issued and one fill is dispensed, and one offer is left open so a
 *      visitor can accept it.
 *   5. Writes web/deployment.js so web/live.html can talk to the contract.
 *
 * The demo wallets' private keys are written into web/deployment.js on purpose,
 * so anyone opening the public page can act as each organisation without
 * installing a wallet. They only ever hold small amounts of TEST ETH.
 * Your own MetaMask key is NEVER written anywhere by this script.
 */
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");
const { demoFillCodes } = require("../offchain/rxcode");
const { cidOf, encryptForConsortium } = require("../offchain/ipfs");

const { ethers } = hre;
const PROD = "MORPH-10MG-TAB";
const LOT = "MOR-2026-001";
const QTY = 2000;
const DAY = 86400;

const { BUDGET, ADMIN_GAS, PRICE_HEADROOM_NUM, PRICE_HEADROOM_DEN } = require("./budgets");
const ROLE_OF = { regulator: "REGULATOR_ROLE", manufacturer: "MANUFACTURER_ROLE", wholesaler: "WHOLESALER_ROLE", pharmacy: "PHARMACY_ROLE", prescriber: "PRESCRIBER_ROLE" };
const ORG = {
  regulator: "National Medicines Regulator (fictional)",
  manufacturer: "Lumora Biologics Ltd (fictional)",
  wholesaler: "ColdRoute Distribution (fictional)",
  pharmacy: "Westside Community Pharmacy (fictional)",
  prescriber: "Dr A. Rahman, prescriber (fictional)",
};

const fmt = (wei) => `${Number(ethers.formatEther(wei)).toFixed(5)} ETH`;
let step = 0;
const log = (msg) => console.log(`[${String(++step).padStart(2, "0")}] ${msg}`);

async function send(label, txPromise) {
  const tx = await txPromise;
  const rc = await tx.wait();
  log(`${label}  (tx ${tx.hash.slice(0, 12)}…, gas ${rc.gasUsed})`);
  return rc;
}

async function main() {
  const net = await ethers.provider.getNetwork();
  const signers = await ethers.getSigners();
  if (signers.length === 0) {
    throw new Error("No deployer key. Run:  npx hardhat vars set SEPOLIA_PRIVATE_KEY  and paste your MetaMask test account's private key.");
  }
  const admin = signers[0];
  const balance = await ethers.provider.getBalance(admin.address);
  const fee = await ethers.provider.getFeeData();
  const price = fee.maxFeePerGas ?? fee.gasPrice;
  const fundingPrice = (price * PRICE_HEADROOM_NUM) / PRICE_HEADROOM_DEN; // headroom on today's gas price for the demo wallets

  const fundTotal = Object.values(BUDGET).reduce((s, g) => s + BigInt(g), 0n) * fundingPrice;
  const needed = fundTotal + ADMIN_GAS * price;

  console.log(`\nNetwork:        ${hre.network.name} (chain ${net.chainId})`);
  console.log(`Your account:   ${admin.address}`);
  console.log(`Balance:        ${fmt(balance)}`);
  console.log(`Gas price now:  ${ethers.formatUnits(price, "gwei")} gwei`);
  console.log(`Estimated need: ${fmt(needed)}\n`);
  if (balance < needed) {
    throw new Error(`Not enough test ETH. Get at least ${fmt(needed - balance)} more from a faucet, then run this again.`);
  }

  // ---- 1. Deploy --------------------------------------------------------------
  const Factory = await ethers.getContractFactory("RxGuard", admin);
  const g = await Factory.deploy(admin.address);
  const deployTx = g.deploymentTransaction();
  const deployRc = await deployTx.wait();
  const address = await g.getAddress();
  log(`Contract deployed at ${address} (block ${deployRc.blockNumber})`);

  // ---- 2. Demo wallets, funding and roles ------------------------------------
  const wallets = {};
  for (const role of Object.keys(BUDGET)) wallets[role] = ethers.Wallet.createRandom().connect(ethers.provider);
  for (const [role, w] of Object.entries(wallets)) {
    await send(`Funded ${role} wallet ${w.address.slice(0, 10)}… with ${fmt(BigInt(BUDGET[role]) * fundingPrice)}`,
      admin.sendTransaction({ to: w.address, value: BigInt(BUDGET[role]) * fundingPrice }));
  }
  for (const [role, w] of Object.entries(wallets)) {
    await send(`Granted ${ROLE_OF[role]} to ${role}`, g.connect(admin).grantRole(await g[ROLE_OF[role]](), w.address));
  }
  const as = (role) => g.connect(wallets[role]);

  // ---- 3. The story -------------------------------------------------------------
  await send("Regulator set the pharmacy's quota: 500 units per 30 days", as("regulator").setQuota(wallets.pharmacy.address, PROD, 500));

  const coa = Buffer.from(JSON.stringify({ doc: "Certificate of Analysis", product: PROD, assay: "99.4%", dissolution: "Pass" }));
  const docsCid = await cidOf(encryptForConsortium(coa).payload);
  const latest = await ethers.provider.getBlock("latest");
  await send(`Manufacturer created lot ${LOT} (${QTY} units)`, as("manufacturer").createLot({ product: PROD, lotNo: LOT, expiry: latest.timestamp + 540 * DAY, quantity: QTY, docsCid }));
  const lotId = await g.lotIdOf(PROD, LOT);

  await send("Manufacturer offered 1,200 units to the wholesaler", as("manufacturer").offerTransfer(lotId, wallets.wholesaler.address, 1200, ethers.id("delivery-note-1"), 7 * DAY));
  await send("Wholesaler accepted", as("wholesaler").acceptTransfer(await g.offerCount()));
  await send("Wholesaler offered 400 units to the pharmacy", as("wholesaler").offerTransfer(lotId, wallets.pharmacy.address, 400, ethers.id("delivery-note-2"), 7 * DAY));
  await send("Pharmacy accepted (quota used: 400 of 500)", as("pharmacy").acceptTransfer(await g.offerCount()));

  const rxA = demoFillCodes(`demo-rx-A|${address}`, 2);
  await send("Prescriber issued prescription 1: 60 units, 2 fills, 7 days apart", as("prescriber").issuePrescription(rxA.hashes, PROD, 60, 60 * DAY, 7 * DAY, wallets.pharmacy.address));
  const rxIdA = await g.rxCount();
  await send("Pharmacy dispensed fill 1 (30 units)", as("pharmacy").dispense(rxIdA, lotId, 30, rxA.secrets[0]));

  const rxB = demoFillCodes(`demo-rx-B|${address}`, 1);
  await send("Prescriber issued prescription 2: 20 units, 1 fill (left for visitors to dispense)", as("prescriber").issuePrescription(rxB.hashes, PROD, 20, 60 * DAY, 0, ethers.ZeroAddress));
  const rxIdB = await g.rxCount();

  await send("Wholesaler offered 100 more units to the pharmacy (left open for visitors to accept)", as("wholesaler").offerTransfer(lotId, wallets.pharmacy.address, 100, ethers.id("delivery-note-3"), 7 * DAY));

  // ---- 4. Write the page configuration ----------------------------------------
  const abi = JSON.parse(g.interface.formatJson());
  const explorer = Number(net.chainId) === 11155111 ? "https://sepolia.etherscan.io" : null;
  const deployment = {
    network: hre.network.name,
    chainId: Number(net.chainId),
    contract: address,
    deployBlock: deployRc.blockNumber,
    deployTx: deployTx.hash,
    deployedAt: new Date().toISOString(),
    admin: admin.address,
    explorer,
    rpcUrls: hre.network.name === "sepolia"
      ? ["https://ethereum-sepolia-rpc.publicnode.com", "https://sepolia.drpc.org", "https://1rpc.io/sepolia"]
      : ["http://127.0.0.1:8545"],
    product: PROD,
    sampleLot: LOT,
    // Public on purpose (test network, demo only). Real secrets are given only to the patient.
    demoPrescriptions: [
      { rxId: Number(rxIdA), note: "Fill 1 already dispensed. Fill 2 is allowed after 7 days.", secrets: rxA.secrets },
      { rxId: Number(rxIdB), note: "Not used yet. Any licensed pharmacy can fill it.", secrets: rxB.secrets },
    ],
    demoWallets: Object.fromEntries(Object.entries(wallets).map(([role, w]) => [role, { org: ORG[role], address: w.address, privateKey: w.privateKey }])),
    abi,
  };
  const outJs = path.join(__dirname, "..", "web", "deployment.js");
  fs.writeFileSync(outJs,
    "// Generated by scripts/deploy-live.js. TEST NETWORK ONLY: the demo wallet keys below hold test ETH, never real money.\n" +
    `window.RXGUARD_DEPLOYMENT = ${JSON.stringify(deployment, null, 2)};\n`);
  fs.mkdirSync(path.join(__dirname, "..", "reports"), { recursive: true });
  const { abi: _omit, demoWallets, demoPrescriptions, ...summary } = deployment;
  fs.writeFileSync(path.join(__dirname, "..", "reports", `deployment-${hre.network.name}.json`),
    JSON.stringify({ ...summary, demoWallets: Object.fromEntries(Object.entries(demoWallets).map(([r, w]) => [r, w.address])) }, null, 2));

  const left = await ethers.provider.getBalance(admin.address);
  console.log(`\nDone. Contract: ${address}`);
  if (explorer) console.log(`View it:        ${explorer}/address/${address}`);
  console.log(`Page config:    web/deployment.js (open web/live.html)`);
  console.log(`Your balance:   ${fmt(left)}\n`);
}

main().catch((e) => {
  console.error(`\nERROR: ${e.shortMessage || e.message}\n`);
  process.exit(1);
});
