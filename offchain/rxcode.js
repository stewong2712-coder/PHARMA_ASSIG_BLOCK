/**
 * Prescription codes.
 *
 * The ledger never stores who the patient is. When a prescriber issues a
 * prescription they generate one random secret per allowed fill. The patient
 * gets the secrets (printed or in an app); the ledger gets only keccak256 of
 * each. A pharmacy proves it holds the patient's prescription by revealing the
 * secret for the current fill, and the contract checks it against the hash.
 */
const crypto = require("crypto");
const { ethers } = require("ethers");

function makeFillCodes(fills) {
  const secrets = Array.from({ length: fills }, () => "0x" + crypto.randomBytes(32).toString("hex"));
  return { secrets, hashes: secrets.map((s) => ethers.keccak256(s)) };
}

/** Deterministic codes for demos and tests: seed + fill number. */
function demoFillCodes(seed, fills) {
  const secrets = Array.from({ length: fills }, (_, i) => ethers.id(`${seed}|fill|${i + 1}`));
  return { secrets, hashes: secrets.map((s) => ethers.keccak256(s)) };
}

/** Short code a human can type: first 12 hex characters of the secret. Demo only. */
const shortCode = (secret) => secret.slice(2, 14).toUpperCase();

module.exports = { makeFillCodes, demoFillCodes, shortCode };
