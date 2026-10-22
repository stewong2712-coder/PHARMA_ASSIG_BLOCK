# RxGuard: controlled-medicine custody, quota and e-prescription ledger

Prototype for the *Blockchain Foundations and Applications* assignment (Part B, second scenario).
Where PharmaChain tracks one refrigerated product pack by pack, RxGuard tracks **controlled medicines
(for example opioid tablets) by quantity** from Manufacturer to Wholesaler to Pharmacy to Patient, with a
**regulator quota** and **prescriptions that carry no patient identity**. It runs on an EVM chain with
role-based writes (Hyperledger Besu with QBFT in a consortium, or Ethereum Sepolia for the public demo).
All organisation names are fictional.

## What it does that PharmaChain does not
| Feature | How it works |
| --- | --- |
| Quantity custody | Stock is a number per holder, so one lot can be split across many wholesalers and pharmacies |
| Offer, accept, reject, expire | Units sit in escrow while an offer is open. The receiver accepts or rejects, the sender cancels, or anyone releases the escrow after the timeout |
| Regulator quota | A pharmacy can only receive a product if the regulator set a quota for it, and no more than the quota per 30 days |
| Prescriptions | The prescriber stores one hash per allowed fill. The patient holds the secret codes. The ledger has no name or ID |
| Fill rules | Allowed units, number of fills, minimum days between fills, optional reserved pharmacy, expiry |
| Books always balance | issued = held + in transit + dispensed + lost + destroyed. `reconcile()` checks it for the regulator |
| Loss and destruction | Holders report losses and witnessed destruction, which keeps the books balanced and leaves an audit trail |
| Recall and suspension | The regulator or manufacturer recalls a lot. The regulator suspends or reinstates a member |

## Layout
| Path | What it is |
| --- | --- |
| `contracts/RxGuard.sol` | The smart contract |
| `test/RxGuard.test.js` | Hardhat test suite (15 tests) |
| `extras/foundry/RxGuard.t.sol` | Same rules as a Foundry suite (21 tests incl. a fuzz test). Optional |
| `offchain/rxcode.js` | Makes prescription secret codes and their hashes |
| `offchain/ipfs.js` | CIDv1 computation and AES-256-GCM encryption for confidential documents (same as PharmaChain) |
| `scripts/simulate.js` | End-to-end story on a local chain. Writes `reports/simulation.json` |
| `scripts/deploy.js` | Deploys to a local or consortium network |
| `scripts/deploy-live.js` | Deploys to Sepolia, creates and funds five demo wallets, runs a short story, writes `web/deployment.js` |
| `scripts/topup-live.js` | Refills the demo wallets with test ETH |
| `web/live.html` | Live page: portal for all five roles, plus a patient lot check |
| `network/qbft-genesis.example.json` | Example Besu QBFT genesis for a 7-validator consortium |
| `DEPLOYMENT_GUIDE.md` | Step-by-step guide from a free test wallet to a public link |

## Run
```bash
npm install --legacy-peer-deps
npm test           # compiles and runs the tests + gas report
npm run simulate   # end-to-end scenario -> reports/simulation.json
```
Solidity 0.8.24 (solc-js from npm), OpenZeppelin Contracts 5.x, Hardhat 2.x, ethers 6.

## Live deployment (Sepolia test network)
See `DEPLOYMENT_GUIDE.md`. In short:
```bash
npx hardhat vars set SEPOLIA_PRIVATE_KEY <your MetaMask TEST account private key>
npx hardhat run scripts/deploy-live.js --network sepolia
```
Then open `web/live.html`, or publish the `web` folder (for example with GitHub Pages).
The demo wallet keys in `web/deployment.js` are public by design and only hold test ETH.

## Testing status (please read)
* The contract was compiled with solc 0.8.24 and tested with the Foundry suite in `extras/foundry`: 21 of 21 pass, including a fuzz test of the balance rule.
* `scripts/simulate.js` and `scripts/deploy-live.js` were run end to end against a local test chain, and `web/live.html` was driven in a headless browser against that chain (accept, dispense, replay blocked, quota blocked, prescribe, recall, patient check).
* `test/RxGuard.test.js` mirrors the Foundry tests for Hardhat. An earlier 21-test version of it was run on the user's own computer and all 21 passed. The current 15-test version merges the same checks into fewer tests and has not been run by the author, so run `npm test` and expect 15 passing.
* Nothing was deployed to Sepolia. That step needs your own wallet.

## Known limits (worth writing about)
* **A revealed prescription code can be copied.** When a pharmacy dispenses, the secret for that fill is visible on the chain. Reserving the prescription for one pharmacy removes this risk. On a consortium chain with a private mempool the exposure is smaller.
* **Reading is public.** Anyone can read quantities, holders and prescription numbers. For a real deployment, decide which of these a consortium accepts to expose, or use a platform with private channels.
* **Single regulator key.** Quotas, recalls and suspensions come from one role. A real deployment would put that role behind a multisig with named signers.
* **Offers use block time.** Timeouts and quota windows depend on the chain's timestamp, which validators can nudge slightly.
* **Not legal or clinical advice.** The rules (fill gaps, quotas, limits) are illustrative, not taken from any real regulation.
