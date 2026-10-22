# RxGuard Live Deployment Guide
From a free test wallet to a public link your lecturer can use.

This guide takes RxGuard from your laptop onto a public test blockchain (Ethereum Sepolia) and gives you one
public link. On that page your lecturer can check a lot, see every lot, transfer and prescription straight from
the blockchain, and create real entries (register a lot, transfer stock, set a quota, issue a prescription,
dispense, recall) without installing anything. You never need real money. Everything uses free test coins.

## How it fits together
| Part | What it is | Where it lives |
| --- | --- | --- |
| Your MetaMask wallet | Your blockchain account. It pays the (free, test) fees to put the contract on Sepolia and becomes the contract's administrator | Browser extension on your laptop |
| The RxGuard contract | The contract from `contracts/RxGuard.sol`, running at a permanent public address | Sepolia test network |
| Five demo wallets | Regulator, manufacturer, wholesaler, pharmacy and prescriber. The deploy script creates them and gives each a little test ETH | Sepolia; their keys are in `web/deployment.js` |
| `web/live.html` | The live page. It reads the contract for everyone and uses the demo wallets to send transactions, so visitors need no wallet | GitHub Pages (your public link) |

The demo wallets' keys are public on purpose, so anyone can act as each organisation. That is safe because they hold
only small amounts of test ETH. Your own MetaMask key is never put in any file.

Time needed: about 1.5 to 2 hours, plus waiting for the faucet. Do Steps 1 to 4 a day early in case the faucet is slow.

## Step 1: Install MetaMask
1. Open Google Chrome or Microsoft Edge.
2. Go to metamask.io and click Download. Use only the official site; fake extensions exist.
3. Add the extension and pin its fox icon to the toolbar.

## Step 2: Create a new wallet for this project
1. Click the fox icon, choose **Create a new wallet**, and set a password (it only unlocks MetaMask on this laptop).
2. MetaMask shows a 12-word Secret Recovery Phrase. Write it on paper, in order, and keep it safe. Never type it into a website, document or chat, and never share it.
3. Use this wallet only for this project and test networks. If anyone asks for your recovery phrase, it is a scam.

## Step 3: Switch MetaMask to the Sepolia test network
1. Click the network name at the top left and turn on **Show test networks** (or Settings > Advanced).
2. Select **Sepolia**. Your balance shows 0 SepoliaETH.
3. Copy your address (starts with `0x`, 42 characters). It is public and safe to share.

## Step 4: Get free test ETH from a faucet
The amount you need depends on today's gas price on Sepolia. The deploy script prints the exact amount in Step 7 and stops before spending anything if your balance is too low. Get as much as the faucet allows (0.05 SepoliaETH is usually enough when gas is low).

| Faucet | Address | Notes |
| --- | --- | --- |
| Google Cloud Web3 faucet | cloud.google.com/application/web3/faucet/ethereum/sepolia | Sign in with Google, paste your address, click Receive |
| QuickNode faucet | faucet.quicknode.com/ethereum/sepolia | The base amount needs no account |
| Sepolia PoW faucet | sepolia-faucet.pk910.de | Mine in the browser for a while, then stop and claim |

Wait 1 to 5 minutes and check MetaMask. Faucet rules change often. If one asks you to pay, skip it.

## Step 5: Get the project
1. Extract `RxGuard-source.zip` into Documents. This creates `Documents\rxguard`.
2. Open the folder, right-click an empty area and choose **Open Git Bash here**.
3. Install and test:
   ```bash
   npm install --legacy-peer-deps
   npm test
   ```
   You should see **15 passing**. If one fails, copy the message and fix or ask before continuing. Do not deploy with failing tests.

## Step 6: Give Hardhat your wallet's key (safely)
Hardhat needs your MetaMask test account's private key to sign the deployment. Its built-in secret store keeps the key outside the project folder, so it can never be uploaded to GitHub by mistake.
1. In MetaMask click the three dots next to your account, then Account details, then **Show private key**, enter your password and copy it.
2. In Git Bash (replace the placeholder; paste with Shift+Insert):
   ```bash
   npx hardhat vars set SEPOLIA_PRIVATE_KEY PASTE_YOUR_KEY_HERE
   clear
   ```
3. Check it is stored: `npx hardhat vars list` shows `SEPOLIA_PRIVATE_KEY` without the value.

Never paste the private key into the report, a chat, GitHub or any file in the project.

## Step 7: Deploy RxGuard to Sepolia
```bash
npx hardhat run scripts/deploy-live.js --network sepolia
```
The script prints a summary and checks your balance, then runs about 21 numbered steps, waiting about 12 seconds for each. The whole run takes 4 to 6 minutes; leave the window alone.

| Steps | What the script does |
| --- | --- |
| 01 | Puts the contract on Sepolia; your MetaMask account becomes the administrator |
| 02 to 06 | Creates five demo wallets and sends each some test ETH |
| 07 to 11 | Gives each demo wallet its role |
| 12 | The regulator sets the pharmacy's quota: 500 units per 30 days |
| 13 to 17 | The manufacturer creates lot MOR-2026-001 (2,000 units) and sends 1,200 to the wholesaler, who sends 400 to the pharmacy (quota used: 400 of 500) |
| 18 to 19 | The prescriber issues a 2-fill prescription (60 units) and the pharmacy dispenses fill 1 |
| 20 | A second prescription (20 units, 1 fill) is issued and left for visitors to dispense |
| 21 | The wholesaler offers 100 more units to the pharmacy and leaves the offer open for visitors to accept |

It then writes `web/deployment.js` (contract address, interface, demo wallets and the demo prescription codes) and a summary in `reports/deployment-sepolia.json`. Copy the contract address from the last lines into your report.

If something goes wrong:
| Message | What to do |
| --- | --- |
| Not enough test ETH. Get at least ... more | Get more from another faucet, then run the same command again. Nothing has been deployed yet |
| insufficient funds for gas ... (part-way through the steps) | A demo wallet ran dry. Use the updated scripts (budgets in `scripts/budgets.js`) and run the deploy again. It deploys a fresh contract and new demo wallets |
| No deployer key | Redo Step 6 and check the spelling `SEPOLIA_PRIVATE_KEY` |
| A network or timeout error part-way | Run the command again. It deploys a fresh contract and writes a new `deployment.js`; the half-finished one is ignored |

## Step 8: See your contract on Etherscan
Open the **View it** link the script printed (for example `https://sepolia.etherscan.io/address/0x...`). Under Transactions you see the contract creation and every role grant, lot, transfer and prescription. Take a screenshot for your report as proof that the system runs on a real public blockchain.

## Step 9: Try the live page on your laptop
Open `web/live.html` in a browser. The header shows a block number and your contract address, and the page lists lot MOR-2026-001 with bars showing where every unit is.

Each action is a real transaction and takes about 12 seconds. A box in the corner shows progress and a link to each transaction.

| As | Do this | What you should see |
| --- | --- | --- |
| Pharmacy | Accept the open offer of 100 units in Transfers | Pharmacy stock goes from 370 to 470; the quota is now fully used (500) |
| Pharmacy | Press "Rx #2, fill 1" then Dispense | Pharmacy stock drops by 20 and the prescription shows Completed |
| Pharmacy | Press Dispense again | Refused: the prescription is completed |
| Wholesaler | Offer 100 more units to the pharmacy, then accept as the pharmacy | Refused: over the 30-day quota |
| Prescriber | Issue a prescription | The page shows the secret codes once. Save them: the ledger keeps only their hashes |
| Regulator | Recall lot | The lot shows Recalled, and dispensing is refused |
| Patient lot check | Press "Real lot" and "Made-up lot" | Genuine (or Recalled after a recall) and Not recognised |

## Step 10: Publish the public link (GitHub Pages)
1. Create a new public repository on GitHub, for example `rxguard`.
2. Upload the contents of the `web` folder, including `deployment.js` (the demo keys are test-only and public by design). Do not upload anything else from the project unless you want to.
3. In the repository, go to Settings > Pages, choose the main branch and the root folder, and save.
4. After a minute your page is at `https://<your-username>.github.io/rxguard/live.html`. Put that link in your report.

## Step 11: Keep it working
If the page says a demo wallet is out of test ETH, get more from a faucet and run:
```bash
npx hardhat run scripts/topup-live.js --network sepolia
```
Sepolia is a test network and its public endpoints can be slow or change. The page tries three in turn. If all fail, refresh a few minutes later.

## Checklist for your report
- The contract address and the Etherscan link
- A screenshot of the transactions on Etherscan
- A screenshot of the live page showing the lot bars and a refused action (quota or replayed code)
- One paragraph on the limits in README.md (public reads, single regulator key, copied prescription codes)
