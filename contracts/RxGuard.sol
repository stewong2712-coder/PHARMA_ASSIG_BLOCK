// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title RxGuard
 * @notice Quantity-based custody, regulator quota and e-prescription ledger for
 *         controlled medicines (for example opioid tablets).
 *
 *         Manufacturer -> Wholesaler -> Pharmacy -> Patient
 *
 * How it differs from a cold-chain / serial-number design
 *  - Stock is tracked as quantities per holder, not as one custodian per batch,
 *    so a lot of 10,000 units can be split across many wholesalers and pharmacies.
 *  - A transfer is a two-step offer/accept. The units are held in escrow while
 *    the offer is open, so they cannot be offered twice. An offer can be accepted,
 *    rejected, cancelled by the sender, or expire.
 *  - The regulator assigns each pharmacy a quota per product per 30 days. A
 *    pharmacy that is not licensed for a product (quota 0) cannot receive it.
 *  - Prescriptions are issued by licensed prescribers. The ledger stores only a
 *    commitment (one hash per allowed fill), never the patient's identity.
 *  - Every unit is accounted for: issued = held + in transit + dispensed + lost +
 *    destroyed. The regulator can check this at any time with reconcile().
 *
 * Permissioned writes (roles); reads are public.
 */
contract RxGuard is AccessControl {
    // ------------------------------------------------------------------
    // Roles and constants
    // ------------------------------------------------------------------
    bytes32 public constant REGULATOR_ROLE = keccak256("REGULATOR_ROLE");
    bytes32 public constant MANUFACTURER_ROLE = keccak256("MANUFACTURER_ROLE");
    bytes32 public constant WHOLESALER_ROLE = keccak256("WHOLESALER_ROLE");
    bytes32 public constant PHARMACY_ROLE = keccak256("PHARMACY_ROLE");
    bytes32 public constant PRESCRIBER_ROLE = keccak256("PRESCRIBER_ROLE");

    uint64 public constant QUOTA_PERIOD = 30 days;
    uint64 public constant MAX_OFFER_TTL = 7 days;
    uint64 public constant MAX_RX_VALIDITY = 90 days;
    uint8 public constant MAX_FILLS = 6;

    // ------------------------------------------------------------------
    // Data model
    // ------------------------------------------------------------------
    enum LotStatus {
        None,
        Active,
        Recalled
    }

    enum OfferStatus {
        None,
        Open,
        Accepted,
        Rejected,
        Cancelled,
        Expired
    }

    enum RxStatus {
        None,
        Active,
        Completed,
        Cancelled
    }

    struct LotInput {
        string product; // e.g. "MORPH-10MG-TAB"
        string lotNo;
        uint64 expiry; // unix seconds
        uint32 quantity; // units manufactured
        string docsCid; // IPFS CID of certificate of analysis + batch record
    }

    struct Lot {
        string product;
        string lotNo;
        bytes32 productId;
        uint64 expiry;
        uint32 issued;
        uint32 inTransit; // units in escrow in open offers
        uint32 dispensed;
        uint32 lost;
        uint32 destroyed;
        address manufacturer;
        LotStatus status;
        string docsCid;
        uint64 createdAt;
    }

    struct Offer {
        bytes32 lotId;
        address from;
        address to;
        uint32 qty;
        uint64 createdAt;
        uint64 expiresAt;
        bytes32 docHash; // hash of the signed delivery note held off-chain
        OfferStatus status;
    }

    struct Usage {
        uint64 windowStart;
        uint32 received;
    }

    struct Rx {
        address prescriber;
        bytes32 productId;
        uint32 totalUnits;
        uint32 filledUnits;
        uint8 fills;
        uint64 issuedAt;
        uint64 validUntil;
        uint64 minIntervalSec;
        uint64 lastFillAt;
        address designatedPharmacy; // zero address = any licensed pharmacy
        RxStatus status;
        bytes32[] fillHashes; // keccak256(secret) for fill 1, 2, ...
    }

    enum LotVerdict {
        Unknown,
        Genuine,
        Recalled,
        Expired
    }

    enum RxVerdict {
        Unknown,
        Valid,
        Expired,
        Completed,
        Cancelled,
        TooSoon
    }

    mapping(bytes32 => Lot) private lots;
    bytes32[] private lotIds;
    mapping(bytes32 => mapping(address => uint32)) public stock; // lotId => holder => units
    mapping(uint256 => Offer) private offers;
    uint256 public offerCount;

    mapping(bytes32 => mapping(address => uint32)) public quotaPerPeriod; // productId => pharmacy => units
    mapping(bytes32 => mapping(address => Usage)) public usage;
    mapping(address => bool) public suspended;
    mapping(address => uint32) public lossCount; // number of loss reports per holder (audit signal)

    mapping(uint256 => Rx) private prescriptions;
    uint256 public rxCount;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------
    event LotCreated(bytes32 indexed lotId, address indexed manufacturer, string product, string lotNo, uint32 quantity, string docsCid);
    event OfferCreated(uint256 indexed offerId, bytes32 indexed lotId, address indexed from, address to, uint32 qty, uint64 expiresAt, bytes32 docHash);
    event OfferAccepted(uint256 indexed offerId, bytes32 indexed lotId, address indexed to, uint32 qty);
    event OfferRejected(uint256 indexed offerId, bytes32 indexed lotId, address indexed by, string reasonCid);
    event OfferCancelled(uint256 indexed offerId, bytes32 indexed lotId, address indexed by);
    event OfferExpired(uint256 indexed offerId, bytes32 indexed lotId);
    event QuotaSet(address indexed pharmacy, bytes32 indexed productId, uint32 perPeriod);
    event LotRecalled(bytes32 indexed lotId, address indexed by, string reason);
    event MemberSuspended(address indexed member, address indexed by, string reason);
    event MemberReinstated(address indexed member, address indexed by);
    event PrescriptionIssued(uint256 indexed rxId, address indexed prescriber, bytes32 indexed productId, uint32 totalUnits, uint8 maxFills, uint64 validUntil, address designatedPharmacy);
    event PrescriptionCancelled(uint256 indexed rxId, address indexed by);
    event Dispensed(uint256 indexed rxId, bytes32 indexed lotId, address indexed pharmacy, uint32 units, uint8 fillNo);
    event LossReported(bytes32 indexed lotId, address indexed holder, uint32 units, string reasonCid);
    event StockDestroyed(bytes32 indexed lotId, address indexed holder, uint32 units, string witnessCid);

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------
    error InvalidInput();
    error LotExists();
    error UnknownLot();
    error LotNotActive();
    error LotExpired();
    error InsufficientStock();
    error InvalidRecipient();
    error Suspended();
    error UnknownOffer();
    error NotOfferRecipient();
    error NotOfferSender();
    error OfferNotOpen();
    error OfferHasExpired();
    error OfferNotExpired();
    error NoQuota();
    error QuotaExceeded();
    error UnknownRx();
    error RxNotActive();
    error RxHasExpired();
    error WrongPharmacy();
    error NoFillsLeft();
    error TooManyUnits();
    error WrongProduct();
    error TooSoon();
    error BadCode();
    error NotAuthorised();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
    function lotIdOf(string calldata product, string calldata lotNo) public pure returns (bytes32) {
        return keccak256(abi.encode(product, lotNo));
    }

    function productIdOf(string memory product) public pure returns (bytes32) {
        return keccak256(bytes(product));
    }

    function _lot(bytes32 lotId) internal view returns (Lot storage l) {
        l = lots[lotId];
        if (l.status == LotStatus.None) revert UnknownLot();
    }

    function _requireTradable(Lot storage l) internal view {
        if (l.status != LotStatus.Active) revert LotNotActive();
        if (block.timestamp >= l.expiry) revert LotExpired();
    }

    function _notSuspended(address who) internal view {
        if (suspended[who]) revert Suspended();
    }

    function _validNext(address from, address to) internal view returns (bool) {
        if (from == to) return false;
        if (hasRole(MANUFACTURER_ROLE, from)) return hasRole(WHOLESALER_ROLE, to);
        if (hasRole(WHOLESALER_ROLE, from)) return hasRole(WHOLESALER_ROLE, to) || hasRole(PHARMACY_ROLE, to);
        return false;
    }

    // ------------------------------------------------------------------
    // Regulator
    // ------------------------------------------------------------------
    function setQuota(address pharmacy, string calldata product, uint32 perPeriod) external onlyRole(REGULATOR_ROLE) {
        if (!hasRole(PHARMACY_ROLE, pharmacy)) revert InvalidInput();
        bytes32 pid = productIdOf(product);
        quotaPerPeriod[pid][pharmacy] = perPeriod;
        emit QuotaSet(pharmacy, pid, perPeriod);
    }

    function suspendMember(address member, string calldata reason) external onlyRole(REGULATOR_ROLE) {
        suspended[member] = true;
        emit MemberSuspended(member, msg.sender, reason);
    }

    function reinstateMember(address member) external onlyRole(REGULATOR_ROLE) {
        suspended[member] = false;
        emit MemberReinstated(member, msg.sender);
    }

    function recallLot(bytes32 lotId, string calldata reason) external {
        Lot storage l = _lot(lotId);
        if (!hasRole(REGULATOR_ROLE, msg.sender) && msg.sender != l.manufacturer) revert NotAuthorised();
        l.status = LotStatus.Recalled;
        emit LotRecalled(lotId, msg.sender, reason);
    }

    // ------------------------------------------------------------------
    // Manufacturer: create a lot
    // ------------------------------------------------------------------
    function createLot(LotInput calldata input) external onlyRole(MANUFACTURER_ROLE) returns (bytes32 lotId) {
        _notSuspended(msg.sender);
        if (
            bytes(input.product).length == 0 || bytes(input.lotNo).length == 0 || input.quantity == 0
                || input.expiry <= block.timestamp || bytes(input.docsCid).length == 0
        ) revert InvalidInput();
        lotId = keccak256(abi.encode(input.product, input.lotNo));
        if (lots[lotId].status != LotStatus.None) revert LotExists();

        Lot storage l = lots[lotId];
        l.product = input.product;
        l.lotNo = input.lotNo;
        l.productId = productIdOf(input.product);
        l.expiry = input.expiry;
        l.issued = input.quantity;
        l.manufacturer = msg.sender;
        l.status = LotStatus.Active;
        l.docsCid = input.docsCid;
        l.createdAt = uint64(block.timestamp);
        stock[lotId][msg.sender] = input.quantity;
        lotIds.push(lotId);
        emit LotCreated(lotId, msg.sender, input.product, input.lotNo, input.quantity, input.docsCid);
    }

    // ------------------------------------------------------------------
    // Transfers: offer -> accept / reject / cancel / expire
    // ------------------------------------------------------------------
    function offerTransfer(bytes32 lotId, address to, uint32 qty, bytes32 docHash, uint64 ttl) external returns (uint256 id) {
        Lot storage l = _lot(lotId);
        _requireTradable(l);
        _notSuspended(msg.sender);
        _notSuspended(to);
        if (qty == 0 || ttl == 0 || ttl > MAX_OFFER_TTL) revert InvalidInput();
        if (!_validNext(msg.sender, to)) revert InvalidRecipient();
        if (stock[lotId][msg.sender] < qty) revert InsufficientStock();

        stock[lotId][msg.sender] -= qty;
        l.inTransit += qty;
        id = ++offerCount;
        offers[id] = Offer({
            lotId: lotId,
            from: msg.sender,
            to: to,
            qty: qty,
            createdAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + ttl,
            docHash: docHash,
            status: OfferStatus.Open
        });
        emit OfferCreated(id, lotId, msg.sender, to, qty, uint64(block.timestamp) + ttl, docHash);
    }

    function _openOffer(uint256 id) internal view returns (Offer storage o) {
        o = offers[id];
        if (o.status == OfferStatus.None) revert UnknownOffer();
        if (o.status != OfferStatus.Open) revert OfferNotOpen();
    }

    function acceptTransfer(uint256 id) external {
        Offer storage o = _openOffer(id);
        if (msg.sender != o.to) revert NotOfferRecipient();
        if (block.timestamp > o.expiresAt) revert OfferHasExpired();
        Lot storage l = lots[o.lotId];
        _requireTradable(l);
        _notSuspended(msg.sender);
        _notSuspended(o.from);
        if (hasRole(PHARMACY_ROLE, msg.sender)) _consumeQuota(l.productId, msg.sender, o.qty);

        o.status = OfferStatus.Accepted;
        l.inTransit -= o.qty;
        stock[o.lotId][msg.sender] += o.qty;
        emit OfferAccepted(id, o.lotId, msg.sender, o.qty);
    }

    function _consumeQuota(bytes32 productId, address pharmacy, uint32 qty) internal {
        uint32 quota = quotaPerPeriod[productId][pharmacy];
        if (quota == 0) revert NoQuota();
        Usage storage u = usage[productId][pharmacy];
        if (block.timestamp >= u.windowStart + QUOTA_PERIOD) {
            u.windowStart = uint64(block.timestamp);
            u.received = 0;
        }
        if (uint256(u.received) + qty > quota) revert QuotaExceeded();
        u.received += qty;
    }

    function _returnToSender(Offer storage o) internal {
        stock[o.lotId][o.from] += o.qty;
        lots[o.lotId].inTransit -= o.qty;
    }

    function rejectTransfer(uint256 id, string calldata reasonCid) external {
        Offer storage o = _openOffer(id);
        if (msg.sender != o.to) revert NotOfferRecipient();
        o.status = OfferStatus.Rejected;
        _returnToSender(o);
        emit OfferRejected(id, o.lotId, msg.sender, reasonCid);
    }

    function cancelTransfer(uint256 id) external {
        Offer storage o = _openOffer(id);
        if (msg.sender != o.from) revert NotOfferSender();
        o.status = OfferStatus.Cancelled;
        _returnToSender(o);
        emit OfferCancelled(id, o.lotId, msg.sender);
    }

    /// Anyone can release escrowed units once an offer has timed out.
    function expireOffer(uint256 id) external {
        Offer storage o = _openOffer(id);
        if (block.timestamp <= o.expiresAt) revert OfferNotExpired();
        o.status = OfferStatus.Expired;
        _returnToSender(o);
        emit OfferExpired(id, o.lotId);
    }

    // ------------------------------------------------------------------
    // Prescriptions
    // ------------------------------------------------------------------
    /// @param fillHashes keccak256 of the secret printed on the patient's prescription, one per allowed fill
    function issuePrescription(
        bytes32[] calldata fillHashes,
        string calldata product,
        uint32 totalUnits,
        uint64 validFor,
        uint64 minIntervalSec,
        address designatedPharmacy
    ) external onlyRole(PRESCRIBER_ROLE) returns (uint256 rxId) {
        _notSuspended(msg.sender);
        if (
            fillHashes.length == 0 || fillHashes.length > MAX_FILLS || totalUnits == 0 || validFor == 0
                || validFor > MAX_RX_VALIDITY || bytes(product).length == 0
        ) revert InvalidInput();
        if (designatedPharmacy != address(0) && !hasRole(PHARMACY_ROLE, designatedPharmacy)) revert InvalidInput();

        rxId = ++rxCount;
        Rx storage r = prescriptions[rxId];
        r.prescriber = msg.sender;
        r.productId = productIdOf(product);
        r.totalUnits = totalUnits;
        r.issuedAt = uint64(block.timestamp);
        r.validUntil = uint64(block.timestamp) + validFor;
        r.minIntervalSec = minIntervalSec;
        r.designatedPharmacy = designatedPharmacy;
        r.status = RxStatus.Active;
        for (uint256 i = 0; i < fillHashes.length; i++) r.fillHashes.push(fillHashes[i]);
        emit PrescriptionIssued(rxId, msg.sender, r.productId, totalUnits, uint8(fillHashes.length), r.validUntil, designatedPharmacy);
    }

    function cancelPrescription(uint256 rxId) external {
        Rx storage r = prescriptions[rxId];
        if (r.status == RxStatus.None) revert UnknownRx();
        if (msg.sender != r.prescriber && !hasRole(REGULATOR_ROLE, msg.sender)) revert NotAuthorised();
        if (r.status != RxStatus.Active) revert RxNotActive();
        r.status = RxStatus.Cancelled;
        emit PrescriptionCancelled(rxId, msg.sender);
    }

    function dispense(uint256 rxId, bytes32 lotId, uint32 units, bytes32 secret) external onlyRole(PHARMACY_ROLE) {
        _notSuspended(msg.sender);
        Rx storage r = prescriptions[rxId];
        if (r.status == RxStatus.None) revert UnknownRx();
        if (r.status != RxStatus.Active) revert RxNotActive();
        if (block.timestamp > r.validUntil) revert RxHasExpired();
        if (r.designatedPharmacy != address(0) && r.designatedPharmacy != msg.sender) revert WrongPharmacy();
        if (r.fills >= r.fillHashes.length) revert NoFillsLeft();
        if (units == 0 || uint256(r.filledUnits) + units > r.totalUnits) revert TooManyUnits();
        if (r.fills > 0 && block.timestamp < r.lastFillAt + r.minIntervalSec) revert TooSoon();
        if (keccak256(abi.encodePacked(secret)) != r.fillHashes[r.fills]) revert BadCode();

        Lot storage l = _lot(lotId);
        _requireTradable(l);
        if (l.productId != r.productId) revert WrongProduct();
        if (stock[lotId][msg.sender] < units) revert InsufficientStock();

        stock[lotId][msg.sender] -= units;
        l.dispensed += units;
        r.filledUnits += units;
        r.fills += 1;
        r.lastFillAt = uint64(block.timestamp);
        if (r.filledUnits == r.totalUnits || r.fills == r.fillHashes.length) r.status = RxStatus.Completed;
        emit Dispensed(rxId, lotId, msg.sender, units, r.fills);
    }

    // ------------------------------------------------------------------
    // Loss and destruction (keeps the books balanced)
    // ------------------------------------------------------------------
    function reportLoss(bytes32 lotId, uint32 units, string calldata reasonCid) external {
        Lot storage l = _lot(lotId);
        if (units == 0 || bytes(reasonCid).length == 0) revert InvalidInput();
        if (stock[lotId][msg.sender] < units) revert InsufficientStock();
        stock[lotId][msg.sender] -= units;
        l.lost += units;
        lossCount[msg.sender] += 1;
        emit LossReported(lotId, msg.sender, units, reasonCid);
    }

    function destroyStock(bytes32 lotId, uint32 units, string calldata witnessCid) external {
        Lot storage l = _lot(lotId);
        if (units == 0 || bytes(witnessCid).length == 0) revert InvalidInput();
        if (stock[lotId][msg.sender] < units) revert InsufficientStock();
        stock[lotId][msg.sender] -= units;
        l.destroyed += units;
        emit StockDestroyed(lotId, msg.sender, units, witnessCid);
    }

    // ------------------------------------------------------------------
    // Public views
    // ------------------------------------------------------------------
    function verifyLot(string calldata product, string calldata lotNo)
        external
        view
        returns (LotVerdict verdict, uint64 expiry, address manufacturer)
    {
        Lot storage l = lots[keccak256(abi.encode(product, lotNo))];
        if (l.status == LotStatus.None) return (LotVerdict.Unknown, 0, address(0));
        expiry = l.expiry;
        manufacturer = l.manufacturer;
        if (l.status == LotStatus.Recalled) verdict = LotVerdict.Recalled;
        else if (block.timestamp >= l.expiry) verdict = LotVerdict.Expired;
        else verdict = LotVerdict.Genuine;
    }

    /// For the pharmacist at the counter: can this prescription be filled now?
    function verifyRx(uint256 rxId)
        external
        view
        returns (RxVerdict verdict, uint32 unitsLeft, uint8 fillsLeft, uint64 nextFillAt)
    {
        Rx storage r = prescriptions[rxId];
        if (r.status == RxStatus.None) return (RxVerdict.Unknown, 0, 0, 0);
        unitsLeft = r.totalUnits - r.filledUnits;
        fillsLeft = uint8(r.fillHashes.length) - r.fills;
        nextFillAt = r.fills == 0 ? 0 : r.lastFillAt + r.minIntervalSec;
        if (r.status == RxStatus.Cancelled) verdict = RxVerdict.Cancelled;
        else if (r.status == RxStatus.Completed) verdict = RxVerdict.Completed;
        else if (block.timestamp > r.validUntil) verdict = RxVerdict.Expired;
        else if (block.timestamp < nextFillAt) verdict = RxVerdict.TooSoon;
        else verdict = RxVerdict.Valid;
    }

    /// Audit check: every unit ever made must be somewhere. Pass every address that may hold stock.
    function reconcile(bytes32 lotId, address[] calldata holders)
        external
        view
        returns (uint32 issued, uint32 held, uint32 inTransit, uint32 dispensed, uint32 lost, uint32 destroyed, bool balanced)
    {
        Lot storage l = _lot(lotId);
        for (uint256 i = 0; i < holders.length; i++) held += stock[lotId][holders[i]];
        issued = l.issued;
        inTransit = l.inTransit;
        dispensed = l.dispensed;
        lost = l.lost;
        destroyed = l.destroyed;
        balanced = uint256(held) + inTransit + dispensed + lost + destroyed == issued;
    }

    function getLot(bytes32 lotId) external view returns (Lot memory) {
        return _lot(lotId);
    }

    function getOffer(uint256 id) external view returns (Offer memory) {
        if (offers[id].status == OfferStatus.None) revert UnknownOffer();
        return offers[id];
    }

    function getRx(uint256 rxId) external view returns (Rx memory) {
        if (prescriptions[rxId].status == RxStatus.None) revert UnknownRx();
        return prescriptions[rxId];
    }

    function lotCount() external view returns (uint256) {
        return lotIds.length;
    }

    function lotIdAt(uint256 i) external view returns (bytes32) {
        return lotIds[i];
    }
}
