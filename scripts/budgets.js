// Gas each demo wallet is funded for. Measured on Sepolia, where one transaction can cost
// 5 times what a local test chain shows (createLot ~1.4M, offerTransfer ~0.8M, issuePrescription ~1.0M).
// Covers the seeded story plus headroom for visitors to try the page.
module.exports = {
  BUDGET: { regulator: 1_000_000, manufacturer: 4_500_000, wholesaler: 3_500_000, pharmacy: 2_500_000, prescriber: 4_500_000 },
  ADMIN_GAS: 20_000_000n, // contract deployment (can be ~14M on Sepolia) + role grants + funding transfers
  PRICE_HEADROOM_NUM: 3n, // wallets are funded at 1.5x today's gas price
  PRICE_HEADROOM_DEN: 2n,
};
