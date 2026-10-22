/**
 * End-to-end simulation of RxGuard on a local chain.
 *
 *   npx hardhat run scripts/simulate.js
 *
 * Story: an opioid tablet lot (fictional) is split between two wholesalers,
 * reaches a pharmacy under a regulator quota, is dispensed against a two-fill
 * prescription, then a loss is reported and a second lot is recalled. After each
 * phase the books are reconciled. Writes reports/simulation.json.
 * All organisation names are fictional.
 */
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");
const { time } = require("@nomicfoundation/hardhat-network-helpers");
const { demoFillCodes } = require("../offchain/rxcode");
const { cidOf, encryptForConsortium } = require("../offchain/ipfs");

const { ethers } = hre;
const DAY = 86400;
const PROD = "MORPH-10MG-TAB";
const RX_VERDICT = ["Unknown", "Valid", "Expired", "Completed", "Cancelled", "TooSoon"];
const LOT_VERDICT = ["Unknown", "Genuine", "Recalled", "Expired"];

async function main() {
  const [admin, reg, mfr, wh1, wh2, ph, doc] = await ethers.getSigners();
  const actors = {
    regulator: ["National Medicines Regulator (fictional)", reg],
    manufacturer: ["Lumora Biologics Ltd (fictional)", mfr],
    wholesaler1: ["ColdRoute Distribution (fictional)", wh1],
    wholesaler2: ["Meridian Wholesale (fictional)", wh2],
    pharmacy: ["Westside Community Pharmacy (fictional)", ph],
    prescriber: ["Dr A. Rahman (fictional)", doc],
  };
  const g = await (await ethers.getContractFactory("RxGuard")).deploy(admin.address);
  const report = { generatedAt: new Date().toISOString(), actors: Object.fromEntries(Object.entries(actors).map(([k, [n, s]]) => [k, { name: n, address: s.address }])), phases: [], gas: {} };
  const gas = {};
  const run = async (label, p) => { const rc = await (await p).wait(); (gas[label] = gas[label] || []).push(Number(rc.gasUsed)); return rc; };
  const holders = [mfr, wh1, wh2, ph].map((s) => s.address);

  await g.grantRole(await g.REGULATOR_ROLE(), reg.address);
  await g.grantRole(await g.MANUFACTURER_ROLE(), mfr.address);
  await g.grantRole(await g.WHOLESALER_ROLE(), wh1.address);
  await g.grantRole(await g.WHOLESALER_ROLE(), wh2.address);
  await g.grantRole(await g.PHARMACY_ROLE(), ph.address);
  await g.grantRole(await g.PRESCRIBER_ROLE(), doc.address);

  const books = async (lotId, label) => {
    const r = await g.reconcile(lotId, holders);
    const row = { phase: label, issued: Number(r.issued), held: Number(r.held), inTransit: Number(r.inTransit), dispensed: Number(r.dispensed), lost: Number(r.lost), destroyed: Number(r.destroyed), balanced: r.balanced };
    report.phases.push(row);
    console.log(`  books [${label}]: issued ${row.issued} = held ${row.held} + transit ${row.inTransit} + dispensed ${row.dispensed} + lost ${row.lost} + destroyed ${row.destroyed} -> ${row.balanced ? "BALANCED" : "MISMATCH"}`);
    if (!r.balanced) throw new Error("books do not balance");
  };

  console.log("1. Regulator licenses the pharmacy: quota 500 units per 30 days");
  await run("setQuota", g.connect(reg).setQuota(ph.address, PROD, 500));

  console.log("2. Manufacturer registers lot MOR-2026-001 (10,000 units)");
  const docsCid = await cidOf(encryptForConsortium(Buffer.from(JSON.stringify({ doc: "Certificate of Analysis", product: PROD, assay: "99.4%" }))).payload);
  const now = await time.latest();
  await run("createLot", g.connect(mfr).createLot({ product: PROD, lotNo: "MOR-2026-001", expiry: now + 540 * DAY, quantity: 10000, docsCid }));
  const lotId = await g.lotIdOf(PROD, "MOR-2026-001");
  await books(lotId, "after manufacture");

  console.log("3. Lot is split: 6,000 to wholesaler 1, 3,000 to wholesaler 2 (offer, then accept)");
  for (const [w, q] of [[wh1, 6000], [wh2, 3000]]) {
    await run("offerTransfer", g.connect(mfr).offerTransfer(lotId, w.address, q, ethers.id("delivery-note"), DAY));
    await run("acceptTransfer", g.connect(w).acceptTransfer(await g.offerCount()));
  }
  await books(lotId, "after split");

  console.log("4. Wholesaler 1 offers 400 units to the pharmacy; it is accepted. A second offer of 200 would break the quota");
  await run("offerTransfer", g.connect(wh1).offerTransfer(lotId, ph.address, 400, ethers.id("delivery-note-2"), DAY));
  await run("acceptTransfer", g.connect(ph).acceptTransfer(await g.offerCount()));
  await run("offerTransfer", g.connect(wh1).offerTransfer(lotId, ph.address, 200, ethers.id("delivery-note-3"), DAY));
  const overId = await g.offerCount();
  try { await g.connect(ph).acceptTransfer.staticCall(overId); } catch (e) { console.log("   blocked:", e.revert?.name || e.shortMessage); report.quotaBlocked = e.revert?.name || "QuotaExceeded"; }
  await run("cancelTransfer", g.connect(wh1).cancelTransfer(overId));
  await books(lotId, "after quota check");

  console.log("5. Prescriber issues a 2-fill prescription for 60 units; pharmacy fills 30, then must wait 7 days");
  const codes = demoFillCodes("patient-demo-1", 2);
  await run("issuePrescription", g.connect(doc).issuePrescription(codes.hashes, PROD, 60, 30 * DAY, 7 * DAY, ph.address));
  const rx = await g.rxCount();
  await run("dispense", g.connect(ph).dispense(rx, lotId, 30, codes.secrets[0]));
  try { await g.connect(ph).dispense.staticCall(rx, lotId, 30, codes.secrets[1]); } catch (e) { console.log("   blocked:", e.revert?.name); report.earlyRefillBlocked = e.revert?.name; }
  const v1 = await g.verifyRx(rx);
  console.log("   prescription status:", RX_VERDICT[Number(v1.verdict)], `(${v1.unitsLeft} units, ${v1.fillsLeft} fill left)`);
  await time.increase(7 * DAY);
  await run("dispense", g.connect(ph).dispense(rx, lotId, 30, codes.secrets[1]));
  console.log("   prescription status:", RX_VERDICT[Number((await g.verifyRx(rx)).verdict)]);
  await books(lotId, "after dispensing");

  console.log("6. Wholesaler 2 reports 12 units lost in transit and has 8 destroyed under witness");
  await run("reportLoss", g.connect(wh2).reportLoss(lotId, 12, "bafy-police-report"));
  await run("destroyStock", g.connect(wh2).destroyStock(lotId, 8, "bafy-destruction-witness"));
  await books(lotId, "after loss and destruction");

  console.log("7. Regulator recalls the lot; the pharmacy can no longer dispense it");
  await run("recallLot", g.connect(reg).recallLot(lotId, "Potency out of specification"));
  const rx2codes = demoFillCodes("patient-demo-2", 1);
  await g.connect(doc).issuePrescription(rx2codes.hashes, PROD, 10, 30 * DAY, 0, ethers.ZeroAddress);
  try { await g.connect(ph).dispense.staticCall(await g.rxCount(), lotId, 10, rx2codes.secrets[0]); } catch (e) { console.log("   blocked:", e.revert?.name); report.recallBlocked = e.revert?.name; }
  console.log("   patient check:", LOT_VERDICT[Number((await g.verifyLot(PROD, "MOR-2026-001")).verdict)]);
  await books(lotId, "after recall");

  report.gas = Object.fromEntries(Object.entries(gas).map(([k, v]) => [k, { calls: v.length, average: Math.round(v.reduce((a, b) => a + b, 0) / v.length), max: Math.max(...v) }]));
  fs.mkdirSync(path.join(__dirname, "..", "reports"), { recursive: true });
  fs.writeFileSync(path.join(__dirname, "..", "reports", "simulation.json"), JSON.stringify(report, null, 2));
  console.log("\nWrote reports/simulation.json");
}
main().catch((e) => { console.error(e); process.exit(1); });
