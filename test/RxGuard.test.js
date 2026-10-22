const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

const PROD = "MORPH-10MG-TAB";
const LOT = "MOR-2026-001";
const DAY = 24 * 3600;
const RxVerdict = { Unknown: 0n, Valid: 1n, Expired: 2n, Completed: 3n, Cancelled: 4n, TooSoon: 5n };
const LotVerdict = { Unknown: 0n, Genuine: 1n, Recalled: 2n, Expired: 3n };

// The two secrets printed on the patient's prescription (one per allowed fill).
const S1 = ethers.id("secret-1");
const S2 = ethers.id("secret-2");
const fillHashes = () => [ethers.keccak256(S1), ethers.keccak256(S2)];

async function deployFixture() {
  const [admin, reg, mfr, wh1, wh2, ph1, ph2, doc, outsider] = await ethers.getSigners();
  const g = await (await ethers.getContractFactory("RxGuard")).deploy(admin.address);
  await g.grantRole(await g.REGULATOR_ROLE(), reg.address);
  await g.grantRole(await g.MANUFACTURER_ROLE(), mfr.address);
  await g.grantRole(await g.WHOLESALER_ROLE(), wh1.address);
  await g.grantRole(await g.WHOLESALER_ROLE(), wh2.address);
  await g.grantRole(await g.PHARMACY_ROLE(), ph1.address);
  await g.grantRole(await g.PHARMACY_ROLE(), ph2.address);
  await g.grantRole(await g.PRESCRIBER_ROLE(), doc.address);
  await g.connect(reg).setQuota(ph1.address, PROD, 500);
  await g.connect(reg).setQuota(ph2.address, PROD, 100);
  const now = await time.latest();
  await g.connect(mfr).createLot({ product: PROD, lotNo: LOT, expiry: now + 365 * DAY, quantity: 10000, docsCid: "bafyDocs" });
  const lotId = await g.lotIdOf(PROD, LOT);
  const holders = [mfr, wh1, wh2, ph1, ph2].map((s) => s.address);
  return { g, admin, reg, mfr, wh1, wh2, ph1, ph2, doc, outsider, lotId, holders };
}

async function ship(f, from, to, qty) {
  await f.g.connect(from).offerTransfer(f.lotId, to.address, qty, ethers.id("delivery-note"), DAY);
  await f.g.connect(to).acceptTransfer(await f.g.offerCount());
}

async function issueRx(f, { units = 60, interval = 0, pharmacy = ethers.ZeroAddress, product = PROD, hashes = fillHashes() } = {}) {
  await f.g.connect(f.doc).issuePrescription(hashes, product, units, 30 * DAY, interval, pharmacy);
  return f.g.rxCount();
}

async function balanced(f) {
  const r = await f.g.reconcile(f.lotId, f.holders);
  expect(r.balanced).to.equal(true);
  return r;
}

describe("RxGuard", () => {
  describe("lots", () => {
    it("gives all the stock to the manufacturer, once, with valid input, and only a manufacturer can create it", async () => {
      const f = await loadFixture(deployFixture);
      expect(await f.g.stock(f.lotId, f.mfr.address)).to.equal(10000n);
      expect(await f.g.lotCount()).to.equal(1n);
      await balanced(f);
      const now = await time.latest();
      const input = { product: "X", lotNo: "1", expiry: now + DAY, quantity: 1, docsCid: "c" };
      await expect(f.g.connect(f.outsider).createLot(input)).to.be.revertedWithCustomError(f.g, "AccessControlUnauthorizedAccount");
      await expect(f.g.connect(f.mfr).createLot({ ...input, product: PROD, lotNo: LOT })).to.be.revertedWithCustomError(f.g, "LotExists");
      await expect(f.g.connect(f.mfr).createLot({ ...input, expiry: now - 1 })).to.be.revertedWithCustomError(f.g, "InvalidInput");
    });
  });

  describe("transfers", () => {
    it("splits one lot across several wholesalers", async () => {
      const f = await loadFixture(deployFixture);
      await ship(f, f.mfr, f.wh1, 3000);
      await ship(f, f.mfr, f.wh2, 2000);
      expect(await f.g.stock(f.lotId, f.mfr.address)).to.equal(5000n);
      expect(await f.g.stock(f.lotId, f.wh1.address)).to.equal(3000n);
      expect(await f.g.stock(f.lotId, f.wh2.address)).to.equal(2000n);
      await balanced(f);
    });

    it("holds offered units in escrow and only the named recipient can accept", async () => {
      const f = await loadFixture(deployFixture);
      await f.g.connect(f.mfr).offerTransfer(f.lotId, f.wh1.address, 9000, ethers.ZeroHash, DAY);
      expect(await f.g.stock(f.lotId, f.mfr.address)).to.equal(1000n);
      await expect(f.g.connect(f.mfr).offerTransfer(f.lotId, f.wh2.address, 2000, ethers.ZeroHash, DAY))
        .to.be.revertedWithCustomError(f.g, "InsufficientStock");
      await balanced(f);
      await expect(f.g.connect(f.wh2).acceptTransfer(1)).to.be.revertedWithCustomError(f.g, "NotOfferRecipient");
      await expect(f.g.connect(f.mfr).acceptTransfer(1)).to.be.revertedWithCustomError(f.g, "NotOfferRecipient");
    });

    it("returns the escrow when an offer is rejected, cancelled or expires", async () => {
      const f = await loadFixture(deployFixture);
      // 1. rejected by the recipient
      await f.g.connect(f.mfr).offerTransfer(f.lotId, f.wh1.address, 400, ethers.ZeroHash, DAY);
      await f.g.connect(f.wh1).rejectTransfer(1, "bafyReason");
      expect(await f.g.stock(f.lotId, f.mfr.address)).to.equal(10000n);
      await expect(f.g.connect(f.wh1).acceptTransfer(1)).to.be.revertedWithCustomError(f.g, "OfferNotOpen");
      // 2. cancelled by the sender (the recipient cannot cancel)
      await f.g.connect(f.mfr).offerTransfer(f.lotId, f.wh1.address, 400, ethers.ZeroHash, DAY);
      await expect(f.g.connect(f.wh1).cancelTransfer(2)).to.be.revertedWithCustomError(f.g, "NotOfferSender");
      await f.g.connect(f.mfr).cancelTransfer(2);
      expect(await f.g.stock(f.lotId, f.mfr.address)).to.equal(10000n);
      // 3. expires: cannot be accepted late, and anyone can release the escrow
      await f.g.connect(f.mfr).offerTransfer(f.lotId, f.wh1.address, 400, ethers.ZeroHash, DAY);
      await expect(f.g.expireOffer(3)).to.be.revertedWithCustomError(f.g, "OfferNotExpired");
      await time.increase(DAY + 1);
      await expect(f.g.connect(f.wh1).acceptTransfer(3)).to.be.revertedWithCustomError(f.g, "OfferHasExpired");
      await f.g.connect(f.outsider).expireOffer(3);
      expect(await f.g.stock(f.lotId, f.mfr.address)).to.equal(10000n);
      await balanced(f);
    });

    it("only allows manufacturer to wholesaler and wholesaler to wholesaler or pharmacy", async () => {
      const f = await loadFixture(deployFixture);
      await expect(f.g.connect(f.mfr).offerTransfer(f.lotId, f.ph1.address, 10, ethers.ZeroHash, DAY))
        .to.be.revertedWithCustomError(f.g, "InvalidRecipient");
      await ship(f, f.mfr, f.wh1, 100);
      await ship(f, f.wh1, f.ph1, 50);
      await expect(f.g.connect(f.ph1).offerTransfer(f.lotId, f.wh1.address, 10, ethers.ZeroHash, DAY))
        .to.be.revertedWithCustomError(f.g, "InvalidRecipient");
    });
  });

  describe("regulator quota", () => {
    it("caps what a pharmacy can receive in 30 days then resets, and refuses a pharmacy with no quota", async () => {
      const f = await loadFixture(deployFixture);
      await ship(f, f.mfr, f.wh1, 2000);
      await ship(f, f.wh1, f.ph2, 100); // exactly the quota
      await f.g.connect(f.wh1).offerTransfer(f.lotId, f.ph2.address, 1, ethers.ZeroHash, DAY);
      await expect(f.g.connect(f.ph2).acceptTransfer(await f.g.offerCount())).to.be.revertedWithCustomError(f.g, "QuotaExceeded");
      await time.increase(30 * DAY);
      await f.g.connect(f.wh1).offerTransfer(f.lotId, f.ph2.address, 100, ethers.ZeroHash, DAY);
      await f.g.connect(f.ph2).acceptTransfer(await f.g.offerCount());
      // a pharmacy the regulator never licensed for this product
      const [, , , , , , , , , ph3] = await ethers.getSigners();
      await f.g.grantRole(await f.g.PHARMACY_ROLE(), ph3.address);
      await f.g.connect(f.wh1).offerTransfer(f.lotId, ph3.address, 10, ethers.ZeroHash, DAY);
      await expect(f.g.connect(ph3).acceptTransfer(await f.g.offerCount())).to.be.revertedWithCustomError(f.g, "NoQuota");
    });
  });

  describe("prescriptions and dispensing", () => {
    async function stocked() {
      const f = await loadFixture(deployFixture);
      await ship(f, f.mfr, f.wh1, 2000);
      await ship(f, f.wh1, f.ph1, 300);
      return f;
    }

    it("fills a prescription in two parts, respecting the minimum gap", async () => {
      const f = await stocked();
      const rx = await issueRx(f, { units: 60, interval: 7 * DAY, pharmacy: f.ph1.address });
      await f.g.connect(f.ph1).dispense(rx, f.lotId, 30, S1);
      expect(await f.g.stock(f.lotId, f.ph1.address)).to.equal(270n);
      await expect(f.g.connect(f.ph1).dispense(rx, f.lotId, 30, S2)).to.be.revertedWithCustomError(f.g, "TooSoon");
      const mid = await f.g.verifyRx(rx);
      expect(mid.verdict).to.equal(RxVerdict.TooSoon);
      expect(mid.fillsLeft).to.equal(1n);
      await time.increaseTo(mid.nextFillAt);
      await f.g.connect(f.ph1).dispense(rx, f.lotId, 30, S2);
      expect((await f.g.verifyRx(rx)).verdict).to.equal(RxVerdict.Completed);
      await balanced(f);
    });

    it("rejects a wrong code, too many units, the wrong pharmacy and non-pharmacies", async () => {
      const f = await stocked();
      const rx = await issueRx(f, { units: 60, pharmacy: f.ph1.address });
      await expect(f.g.connect(f.ph1).dispense(rx, f.lotId, 10, ethers.id("wrong"))).to.be.revertedWithCustomError(f.g, "BadCode");
      await expect(f.g.connect(f.ph1).dispense(rx, f.lotId, 61, S1)).to.be.revertedWithCustomError(f.g, "TooManyUnits");
      await expect(f.g.connect(f.ph2).dispense(rx, f.lotId, 10, S1)).to.be.revertedWithCustomError(f.g, "WrongPharmacy");
      await expect(f.g.connect(f.outsider).dispense(rx, f.lotId, 10, S1)).to.be.revertedWithCustomError(f.g, "AccessControlUnauthorizedAccount");
      // the second fill's code cannot be used for the first fill
      await expect(f.g.connect(f.ph1).dispense(rx, f.lotId, 10, S2)).to.be.revertedWithCustomError(f.g, "BadCode");
    });

    it("needs stock in the pharmacy and a lot of the prescribed product", async () => {
      const f = await loadFixture(deployFixture);
      await ship(f, f.mfr, f.wh1, 2000);
      await ship(f, f.wh1, f.ph1, 20);
      const rx = await issueRx(f, { units: 60 });
      await expect(f.g.connect(f.ph1).dispense(rx, f.lotId, 30, S1)).to.be.revertedWithCustomError(f.g, "InsufficientStock");
      const other = await issueRx(f, { units: 5, product: "OTHER-DRUG", hashes: [ethers.keccak256(S1)] });
      await expect(f.g.connect(f.ph1).dispense(other, f.lotId, 5, S1)).to.be.revertedWithCustomError(f.g, "WrongProduct");
    });

    it("handles expiry, cancellation and invalid prescriptions, and stores nothing that identifies the patient", async () => {
      const f = await stocked();
      const rx = await issueRx(f);
      const stored = await f.g.getRx(rx);
      expect(stored.fillHashes.length).to.equal(2);
      expect(stored.prescriber).to.equal(f.doc.address);
      await time.increase(31 * DAY);
      await expect(f.g.connect(f.ph1).dispense(rx, f.lotId, 10, S1)).to.be.revertedWithCustomError(f.g, "RxHasExpired");
      expect((await f.g.verifyRx(rx)).verdict).to.equal(RxVerdict.Expired);

      const rx2 = await issueRx(f);
      await expect(f.g.connect(f.outsider).cancelPrescription(rx2)).to.be.revertedWithCustomError(f.g, "NotAuthorised");
      await f.g.connect(f.doc).cancelPrescription(rx2);
      await expect(f.g.connect(f.ph1).dispense(rx2, f.lotId, 10, S1)).to.be.revertedWithCustomError(f.g, "RxNotActive");

      await expect(f.g.connect(f.doc).issuePrescription([], PROD, 10, DAY, 0, ethers.ZeroAddress)).to.be.revertedWithCustomError(f.g, "InvalidInput");
      await expect(f.g.connect(f.outsider).issuePrescription(fillHashes(), PROD, 10, DAY, 0, ethers.ZeroAddress))
        .to.be.revertedWithCustomError(f.g, "AccessControlUnauthorizedAccount");
    });
  });

  describe("recall and suspension", () => {
    it("a recall blocks accepting and dispensing, but the sender can still pull escrow back", async () => {
      const f = await loadFixture(deployFixture);
      await ship(f, f.mfr, f.wh1, 2000);
      await ship(f, f.wh1, f.ph1, 300);
      const rx = await issueRx(f);
      await f.g.connect(f.wh1).offerTransfer(f.lotId, f.ph1.address, 10, ethers.ZeroHash, DAY);
      const open = await f.g.offerCount();
      await expect(f.g.connect(f.outsider).recallLot(f.lotId, "bad")).to.be.revertedWithCustomError(f.g, "NotAuthorised");
      await f.g.connect(f.reg).recallLot(f.lotId, "contamination");
      await expect(f.g.connect(f.ph1).dispense(rx, f.lotId, 10, S1)).to.be.revertedWithCustomError(f.g, "LotNotActive");
      await expect(f.g.connect(f.ph1).acceptTransfer(open)).to.be.revertedWithCustomError(f.g, "LotNotActive");
      await f.g.connect(f.wh1).cancelTransfer(open);
      expect((await f.g.verifyLot(PROD, LOT)).verdict).to.equal(LotVerdict.Recalled);
      await balanced(f);
    });

    it("a suspended member cannot trade or dispense until reinstated", async () => {
      const f = await loadFixture(deployFixture);
      await ship(f, f.mfr, f.wh1, 2000);
      await ship(f, f.wh1, f.ph1, 300);
      const rx = await issueRx(f);
      await expect(f.g.connect(f.outsider).suspendMember(f.ph1.address, "audit")).to.be.revertedWithCustomError(f.g, "AccessControlUnauthorizedAccount");
      await f.g.connect(f.reg).suspendMember(f.ph1.address, "audit");
      await expect(f.g.connect(f.ph1).dispense(rx, f.lotId, 10, S1)).to.be.revertedWithCustomError(f.g, "Suspended");
      await expect(f.g.connect(f.wh1).offerTransfer(f.lotId, f.ph1.address, 10, ethers.ZeroHash, DAY)).to.be.revertedWithCustomError(f.g, "Suspended");
      await f.g.connect(f.reg).reinstateMember(f.ph1.address);
      await f.g.connect(f.ph1).dispense(rx, f.lotId, 10, S1);
    });
  });

  describe("audit", () => {
    it("loss and destruction keep the books balanced", async () => {
      const f = await loadFixture(deployFixture);
      await ship(f, f.mfr, f.wh1, 2000);
      await f.g.connect(f.wh1).reportLoss(f.lotId, 15, "bafyPoliceReport");
      await f.g.connect(f.wh1).destroyStock(f.lotId, 5, "bafyWitnessed");
      expect(await f.g.lossCount(f.wh1.address)).to.equal(1n);
      await expect(f.g.connect(f.wh1).reportLoss(f.lotId, 5000, "x")).to.be.revertedWithCustomError(f.g, "InsufficientStock");
      const r = await balanced(f);
      expect(r.issued).to.equal(10000n);
      expect(r.held).to.equal(9980n);
      expect(r.lost).to.equal(15n);
      expect(r.destroyed).to.equal(5n);
    });

    it("reconcile flags a missing holder", async () => {
      const f = await loadFixture(deployFixture);
      await ship(f, f.mfr, f.wh1, 2000);
      const r = await f.g.reconcile(f.lotId, [f.mfr.address]); // forgot wh1
      expect(r.balanced).to.equal(false);
    });

    it("verifyLot reports unknown and expired lots", async () => {
      const f = await loadFixture(deployFixture);
      expect((await f.g.verifyLot(PROD, "NOPE")).verdict).to.equal(LotVerdict.Unknown);
      await time.increase(366 * DAY);
      expect((await f.g.verifyLot(PROD, LOT)).verdict).to.equal(LotVerdict.Expired);
    });
  });
});
