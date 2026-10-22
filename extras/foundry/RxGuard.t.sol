// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {RxGuard} from "../src/RxGuard.sol";

contract RxGuardTest is Test {
    RxGuard g;
    address admin = address(0xA);
    address reg = address(0xB);
    address mfr = address(0xC);
    address wh1 = address(0xD1);
    address wh2 = address(0xD2);
    address ph1 = address(0xE1);
    address ph2 = address(0xE2);
    address doc = address(0xF1);
    address outsider = address(0x99);
    string constant PROD = "MORPH-10MG-TAB";
    string constant LOT = "MOR-2026-001";
    bytes32 lotId;
    bytes32 s1 = keccak256("secret-1");
    bytes32 s2 = keccak256("secret-2");

    function setUp() public {
        vm.warp(1_800_000_000);
        g = new RxGuard(admin);
        vm.startPrank(admin);
        g.grantRole(g.REGULATOR_ROLE(), reg);
        g.grantRole(g.MANUFACTURER_ROLE(), mfr);
        g.grantRole(g.WHOLESALER_ROLE(), wh1);
        g.grantRole(g.WHOLESALER_ROLE(), wh2);
        g.grantRole(g.PHARMACY_ROLE(), ph1);
        g.grantRole(g.PHARMACY_ROLE(), ph2);
        g.grantRole(g.PRESCRIBER_ROLE(), doc);
        vm.stopPrank();
        vm.startPrank(reg);
        g.setQuota(ph1, PROD, 500);
        g.setQuota(ph2, PROD, 100);
        vm.stopPrank();
        vm.prank(mfr);
        lotId = g.createLot(RxGuard.LotInput(PROD, LOT, uint64(block.timestamp + 365 days), 10_000, "bafyDocs"));
    }

    function _ship(address from, address to, uint32 qty) internal returns (uint256 id) {
        vm.prank(from);
        id = g.offerTransfer(lotId, to, qty, keccak256("note"), 1 days);
        vm.prank(to);
        g.acceptTransfer(id);
    }

    function _rx(uint32 units, uint64 interval, address designated) internal returns (uint256) {
        bytes32[] memory hs = new bytes32[](2);
        hs[0] = keccak256(abi.encodePacked(s1));
        hs[1] = keccak256(abi.encodePacked(s2));
        vm.prank(doc);
        return g.issuePrescription(hs, PROD, units, 30 days, interval, designated);
    }

    function _balanced() internal view {
        address[] memory h = new address[](6);
        h[0] = mfr; h[1] = wh1; h[2] = wh2; h[3] = ph1; h[4] = ph2; h[5] = doc;
        (,,,,,, bool ok) = g.reconcile(lotId, h);
        assertTrue(ok, "books must balance");
    }

    function test_createLot_setsStock() public view {
        assertEq(g.stock(lotId, mfr), 10_000);
        assertEq(g.lotCount(), 1);
        _balanced();
    }

    function test_createLot_onlyManufacturer_noDuplicates_validInput() public {
        vm.prank(outsider);
        vm.expectRevert();
        g.createLot(RxGuard.LotInput("X", "1", uint64(block.timestamp + 1 days), 1, "c"));
        vm.prank(mfr);
        vm.expectRevert(RxGuard.LotExists.selector);
        g.createLot(RxGuard.LotInput(PROD, LOT, uint64(block.timestamp + 1 days), 5, "c"));
        vm.prank(mfr);
        vm.expectRevert(RxGuard.InvalidInput.selector);
        g.createLot(RxGuard.LotInput(PROD, "L2", uint64(block.timestamp - 1), 5, "c"));
    }

    function test_splitLotAcrossWholesalers() public {
        _ship(mfr, wh1, 3000);
        _ship(mfr, wh2, 2000);
        assertEq(g.stock(lotId, mfr), 5000);
        assertEq(g.stock(lotId, wh1), 3000);
        assertEq(g.stock(lotId, wh2), 2000);
        _balanced();
    }

    function test_offerEscrowsStock_and_cannotDoubleOffer() public {
        vm.prank(mfr);
        g.offerTransfer(lotId, wh1, 9000, bytes32(0), 1 days);
        assertEq(g.stock(lotId, mfr), 1000);
        vm.prank(mfr);
        vm.expectRevert(RxGuard.InsufficientStock.selector);
        g.offerTransfer(lotId, wh2, 2000, bytes32(0), 1 days);
        _balanced();
    }

    function test_onlyRecipientAccepts() public {
        vm.prank(mfr);
        uint256 id = g.offerTransfer(lotId, wh1, 100, bytes32(0), 1 days);
        vm.prank(wh2);
        vm.expectRevert(RxGuard.NotOfferRecipient.selector);
        g.acceptTransfer(id);
        vm.prank(mfr);
        vm.expectRevert(RxGuard.NotOfferRecipient.selector);
        g.acceptTransfer(id);
    }

    function test_rejectReturnsStock() public {
        vm.prank(mfr);
        uint256 id = g.offerTransfer(lotId, wh1, 400, bytes32(0), 1 days);
        vm.prank(wh1);
        g.rejectTransfer(id, "bafyReason");
        assertEq(g.stock(lotId, mfr), 10_000);
        _balanced();
        vm.prank(wh1);
        vm.expectRevert(RxGuard.OfferNotOpen.selector);
        g.acceptTransfer(id);
    }

    function test_cancelBySenderOnly() public {
        vm.prank(mfr);
        uint256 id = g.offerTransfer(lotId, wh1, 400, bytes32(0), 1 days);
        vm.prank(wh1);
        vm.expectRevert(RxGuard.NotOfferSender.selector);
        g.cancelTransfer(id);
        vm.prank(mfr);
        g.cancelTransfer(id);
        assertEq(g.stock(lotId, mfr), 10_000);
    }

    function test_offerExpires_andCannotBeAccepted() public {
        vm.prank(mfr);
        uint256 id = g.offerTransfer(lotId, wh1, 400, bytes32(0), 1 days);
        vm.expectRevert(RxGuard.OfferNotExpired.selector);
        g.expireOffer(id);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(wh1);
        vm.expectRevert(RxGuard.OfferHasExpired.selector);
        g.acceptTransfer(id);
        vm.prank(outsider);
        g.expireOffer(id);
        assertEq(g.stock(lotId, mfr), 10_000);
        _balanced();
    }

    function test_invalidRoutes() public {
        vm.prank(mfr);
        vm.expectRevert(RxGuard.InvalidRecipient.selector);
        g.offerTransfer(lotId, ph1, 10, bytes32(0), 1 days); // manufacturer cannot skip the wholesaler
        _ship(mfr, wh1, 100);
        _ship(wh1, ph1, 50);
        vm.prank(ph1);
        vm.expectRevert(RxGuard.InvalidRecipient.selector);
        g.offerTransfer(lotId, wh1, 10, bytes32(0), 1 days); // pharmacies cannot forward stock
    }

    function test_quota_enforced_and_resets() public {
        _ship(mfr, wh1, 2000);
        _ship(wh1, ph2, 100); // exactly the quota
        vm.prank(wh1);
        uint256 id = g.offerTransfer(lotId, ph2, 1, bytes32(0), 1 days);
        vm.prank(ph2);
        vm.expectRevert(RxGuard.QuotaExceeded.selector);
        g.acceptTransfer(id);
        vm.warp(block.timestamp + 30 days);
        vm.prank(wh1);
        uint256 id2 = g.offerTransfer(lotId, ph2, 100, bytes32(0), 1 days);
        vm.prank(ph2);
        g.acceptTransfer(id2); // new window
    }

    function test_unlicensedPharmacyHasNoQuota() public {
        address ph3 = address(0xE3);
        bytes32 role = g.PHARMACY_ROLE();
        vm.prank(admin);
        g.grantRole(role, ph3);
        _ship(mfr, wh1, 100);
        vm.prank(wh1);
        uint256 id = g.offerTransfer(lotId, ph3, 10, bytes32(0), 1 days);
        vm.prank(ph3);
        vm.expectRevert(RxGuard.NoQuota.selector);
        g.acceptTransfer(id);
    }

    function test_dispense_fullFlow_and_partialFills() public {
        _ship(mfr, wh1, 2000);
        _ship(wh1, ph1, 300);
        uint256 rx = _rx(60, 7 days, ph1);
        vm.prank(ph1);
        g.dispense(rx, lotId, 30, s1);
        assertEq(g.stock(lotId, ph1), 270);
        vm.prank(ph1);
        vm.expectRevert(RxGuard.TooSoon.selector);
        g.dispense(rx, lotId, 30, s2);
        (RxGuard.RxVerdict v,, uint8 left, uint64 next) = g.verifyRx(rx);
        assertEq(uint8(v), uint8(RxGuard.RxVerdict.TooSoon));
        assertEq(left, 1);
        vm.warp(next);
        vm.prank(ph1);
        g.dispense(rx, lotId, 30, s2);
        (v,,,) = g.verifyRx(rx);
        assertEq(uint8(v), uint8(RxGuard.RxVerdict.Completed));
        _balanced();
    }

    function test_dispense_guards() public {
        _ship(mfr, wh1, 2000);
        _ship(wh1, ph1, 300);
        uint256 rx = _rx(60, 0, ph1);
        vm.prank(ph1);
        vm.expectRevert(RxGuard.BadCode.selector);
        g.dispense(rx, lotId, 10, keccak256("wrong"));
        vm.prank(ph1);
        vm.expectRevert(RxGuard.TooManyUnits.selector);
        g.dispense(rx, lotId, 61, s1);
        vm.prank(ph2);
        vm.expectRevert(RxGuard.WrongPharmacy.selector);
        g.dispense(rx, lotId, 10, s1);
        vm.prank(outsider);
        vm.expectRevert();
        g.dispense(rx, lotId, 10, s1);
        // second fill code cannot be used for the first fill
        vm.prank(ph1);
        vm.expectRevert(RxGuard.BadCode.selector);
        g.dispense(rx, lotId, 10, s2);
    }

    function test_dispense_needsStockAndRightProduct() public {
        _ship(mfr, wh1, 2000);
        _ship(wh1, ph1, 20);
        uint256 rx = _rx(60, 0, address(0));
        vm.prank(ph1);
        vm.expectRevert(RxGuard.InsufficientStock.selector);
        g.dispense(rx, lotId, 30, s1);
        bytes32[] memory hs = new bytes32[](1);
        hs[0] = keccak256(abi.encodePacked(s1));
        vm.prank(doc);
        uint256 rxOther = g.issuePrescription(hs, "OTHER-DRUG", 5, 30 days, 0, address(0));
        vm.prank(ph1);
        vm.expectRevert(RxGuard.WrongProduct.selector);
        g.dispense(rxOther, lotId, 5, s1);
    }

    function test_rx_expiry_cancel_and_limits() public {
        _ship(mfr, wh1, 2000);
        _ship(wh1, ph1, 300);
        uint256 rx = _rx(60, 0, address(0));
        vm.warp(block.timestamp + 31 days);
        vm.prank(ph1);
        vm.expectRevert(RxGuard.RxHasExpired.selector);
        g.dispense(rx, lotId, 10, s1);
        (RxGuard.RxVerdict v,,,) = g.verifyRx(rx);
        assertEq(uint8(v), uint8(RxGuard.RxVerdict.Expired));

        uint256 rx2 = _rx(60, 0, address(0));
        vm.prank(outsider);
        vm.expectRevert(RxGuard.NotAuthorised.selector);
        g.cancelPrescription(rx2);
        vm.prank(doc);
        g.cancelPrescription(rx2);
        vm.prank(ph1);
        vm.expectRevert(RxGuard.RxNotActive.selector);
        g.dispense(rx2, lotId, 10, s1);

        bytes32[] memory none = new bytes32[](0);
        vm.prank(doc);
        vm.expectRevert(RxGuard.InvalidInput.selector);
        g.issuePrescription(none, PROD, 10, 1 days, 0, address(0));
        vm.prank(outsider);
        vm.expectRevert();
        g.issuePrescription(none, PROD, 10, 1 days, 0, address(0));
    }

    function test_recall_blocksAccept_and_dispense() public {
        _ship(mfr, wh1, 2000);
        _ship(wh1, ph1, 300);
        uint256 rx = _rx(60, 0, address(0));
        vm.prank(wh1);
        uint256 id = g.offerTransfer(lotId, ph1, 10, bytes32(0), 1 days);
        vm.prank(outsider);
        vm.expectRevert(RxGuard.NotAuthorised.selector);
        g.recallLot(lotId, "bad");
        vm.prank(reg);
        g.recallLot(lotId, "contamination");
        vm.prank(ph1);
        vm.expectRevert(RxGuard.LotNotActive.selector);
        g.dispense(rx, lotId, 10, s1);
        vm.prank(ph1);
        vm.expectRevert(RxGuard.LotNotActive.selector);
        g.acceptTransfer(id);
        vm.prank(wh1);
        g.cancelTransfer(id); // sender can still pull escrow back
        (RxGuard.LotVerdict lv,,) = g.verifyLot(PROD, LOT);
        assertEq(uint8(lv), uint8(RxGuard.LotVerdict.Recalled));
        _balanced();
    }

    function test_suspension_blocks_trading_and_dispensing() public {
        _ship(mfr, wh1, 2000);
        _ship(wh1, ph1, 300);
        uint256 rx = _rx(60, 0, address(0));
        vm.prank(outsider);
        vm.expectRevert();
        g.suspendMember(ph1, "audit");
        vm.prank(reg);
        g.suspendMember(ph1, "audit");
        vm.prank(ph1);
        vm.expectRevert(RxGuard.Suspended.selector);
        g.dispense(rx, lotId, 10, s1);
        vm.prank(wh1);
        vm.expectRevert(RxGuard.Suspended.selector);
        g.offerTransfer(lotId, ph1, 10, bytes32(0), 1 days);
        vm.prank(reg);
        g.reinstateMember(ph1);
        vm.prank(ph1);
        g.dispense(rx, lotId, 10, s1);
    }

    function test_lossAndDestruction_keepBooksBalanced() public {
        _ship(mfr, wh1, 2000);
        vm.prank(wh1);
        g.reportLoss(lotId, 15, "bafyPoliceReport");
        vm.prank(wh1);
        g.destroyStock(lotId, 5, "bafyWitnessed");
        assertEq(g.lossCount(wh1), 1);
        vm.prank(wh1);
        vm.expectRevert(RxGuard.InsufficientStock.selector);
        g.reportLoss(lotId, 5000, "x");
        _balanced();
        address[] memory h = new address[](2);
        h[0] = mfr; h[1] = wh1;
        (uint32 issued, uint32 held,, , uint32 lost, uint32 destroyed, bool ok) = g.reconcile(lotId, h);
        assertEq(issued, 10_000); assertEq(held, 9980); assertEq(lost, 15); assertEq(destroyed, 5); assertTrue(ok);
    }

    function test_reconcile_detectsMissingHolder() public {
        _ship(mfr, wh1, 2000);
        address[] memory h = new address[](1);
        h[0] = mfr; // forgot wh1
        (,,,,,, bool ok) = g.reconcile(lotId, h);
        assertFalse(ok);
    }

    function test_verifyLot_unknownAndExpired() public {
        (RxGuard.LotVerdict v,,) = g.verifyLot(PROD, "NOPE");
        assertEq(uint8(v), uint8(RxGuard.LotVerdict.Unknown));
        vm.warp(block.timestamp + 366 days);
        (v,,) = g.verifyLot(PROD, LOT);
        assertEq(uint8(v), uint8(RxGuard.LotVerdict.Expired));
    }

    function testFuzz_conservation(uint32 a, uint32 b, uint32 c) public {
        a = uint32(bound(a, 1, 10_000));
        _ship(mfr, wh1, a);
        b = uint32(bound(b, 1, a));
        vm.prank(wh1);
        uint256 id = g.offerTransfer(lotId, wh2, b, bytes32(0), 1 days);
        c = uint32(bound(c, 0, 2));
        if (c == 0) { vm.prank(wh2); g.acceptTransfer(id); }
        else if (c == 1) { vm.prank(wh2); g.rejectTransfer(id, "r"); }
        else { vm.prank(wh1); g.cancelTransfer(id); }
        _balanced();
    }
}
