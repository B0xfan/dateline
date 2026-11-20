#!/usr/bin/env node
'use strict';
// Dateline buyer keys, run on John's Mac only. Same scheme as Reading Vault's Pro keys, with Dateline's own signing key.
//
//   node scripts/keys.js init        makes the signing key pair once and prints the public half for LicenseLogic.swift
//   node scripts/keys.js batch 150   makes 150 numbered keys in one file, one per line, for Payhip ("From a list")
//   node scripts/keys.js key         makes one numbered key (e.g. John's own)
//   node scripts/keys.js check DLK-… checks a key exactly as the app does
//
// The private key lives in ~/.dateline-keys/private-key.pem, outside the repository (backup in Bitwarden,
// "Dateline buyer key signing key"). Anyone who has it can make keys: never commit, paste or email it.
// Key format (must match keySerial in LicenseLogic.swift): DLK-K<6 digits>.<86-char base64url Ed25519 signature of "K<6 digits>">,
// 98 characters, under Payhip's 100. The first number is random so numbers don't show sales; after that they count up.

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const DIR = process.env.DATELINE_KEYS_DIR || path.join(os.homedir(), '.dateline-keys');
const SWIFT = path.join(__dirname, '..', 'Sources', 'DatelineCore', 'LicenseLogic.swift');  // where publicKeys and revoked live
const KEY_RE = /^DLK-K(\d{6})\.([A-Za-z0-9_-]{86})$/;
const b64url = (buf) => Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
// The raw 32 bytes of an Ed25519 public key, as CryptoKit reads them: the end of its SPKI DER.
const rawPublic = (k) => k.export({ type: 'spki', format: 'der' }).subarray(-32).toString('base64');

function makeKey(n, pem) {
  if (!Number.isInteger(n) || n < 1 || n > 999999) throw new Error('Key numbers run from 1 to 999999.');
  const payload = `K${String(n).padStart(6, '0')}`;
  return `DLK-${payload}.${b64url(crypto.sign(null, Buffer.from(payload), pem))}`;
}

// The public keys and refunded numbers in LicenseLogic.swift, so a check here answers as the app does.
function appLists() {
  const src = fs.readFileSync(SWIFT, 'utf8');
  const keys = /static let publicKeys = \[(.*)\]/.exec(src), revoked = /static let revoked: Set<Int> = \[(.*)\]/.exec(src);
  return {
    publicKeys: keys ? [...keys[1].matchAll(/"([^"]+)"/g)].map((x) => x[1]) : [],
    revoked: revoked ? [...revoked[1].matchAll(/\d+/g)].map(Number) : [],
  };
}

function check(key, lists = appLists()) {
  const m = KEY_RE.exec(String(key || '').replace(/\s+/g, ''));
  if (!m) return null;
  const sig = Buffer.from(m[2].replace(/-/g, '+').replace(/_/g, '/'), 'base64');
  const payload = Buffer.from(`K${m[1]}`);
  const ok = lists.publicKeys.some((raw) => {
    try {
      const der = Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), Buffer.from(raw, 'base64')]);
      return crypto.verify(null, payload, crypto.createPublicKey({ key: der, format: 'der', type: 'spki' }), sig);
    } catch { return false; }
  });
  return ok && !lists.revoked.includes(Number(m[1])) ? Number(m[1]) : null;
}

const FILE_RE = /^(?:payhip-keys|single-key)-(\d+)(?:-to-(\d+))?\.txt$/;
// Reserves numbers after the highest one in any earlier key file or the counter, so numbers never repeat.
function reserve(count) {
  const counter = path.join(DIR, 'next-key-number.txt');
  let first = 0;
  for (const name of fs.readdirSync(DIR)) { const m = FILE_RE.exec(name); if (m) first = Math.max(first, Number(m[2] || m[1]) + 1); }
  if (fs.existsSync(counter)) {
    const saved = Number(fs.readFileSync(counter, 'utf8').trim());
    if (Number.isInteger(saved) && saved >= 1) first = Math.max(first, saved);
    else if (!first) throw new Error(`The key counter file is damaged (${counter}) and there are no key files to go by.`);
  }
  if (!first) first = crypto.randomInt(100000, 900000);
  const last = first + count - 1;
  if (last > 999999) throw new Error('Out of key numbers.');
  return { first, last, commit: () => fs.writeFileSync(counter, String(last + 1)) };
}

function privateKey() {
  const p = path.join(DIR, 'private-key.pem');
  if (!fs.existsSync(p)) throw new Error(`No signing key at ${p}. Run: node scripts/keys.js init`);
  return fs.readFileSync(p, 'utf8');
}

function main([cmd, arg]) {
  if (cmd === 'init') {
    const p = path.join(DIR, 'private-key.pem');
    if (fs.existsSync(p)) throw new Error(`A signing key already exists at ${p}. Not replacing it.`);
    fs.mkdirSync(DIR, { recursive: true, mode: 0o700 });
    const { publicKey, privateKey: priv } = crypto.generateKeyPairSync('ed25519');
    fs.writeFileSync(p, priv.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600, flag: 'wx' });
    console.log(`Made the signing key at ${p}. Back it up to Bitwarden now.\nAdd this to publicKeys in LicenseLogic.swift: "${rawPublic(publicKey)}"`);
  } else if (cmd === 'batch' || cmd === 'key') {
    const n = cmd === 'key' ? 1 : Number(arg);
    if (!Number.isInteger(n) || n < 1 || n > 10000) throw new Error('Say how many keys, 1 to 10000: node scripts/keys.js batch 150');
    const pem = privateKey();
    if (check(makeKey(1, pem)) === null) throw new Error('This signing key\'s public half is not in LicenseLogic.swift, so the app would refuse these keys. Nothing was made.');
    const { first, last, commit } = reserve(n);
    const keys = [];
    for (let i = first; i <= last; i++) keys.push(makeKey(i, pem));
    const out = path.join(DIR, n === 1 && cmd === 'key' ? `single-key-${first}.txt` : `payhip-keys-${first}-to-${last}.txt`);
    fs.writeFileSync(out, `${keys.join('\n')}\n`, { mode: 0o600, flag: 'wx' });  // never over an earlier file
    commit();
    console.log(`Made ${n} ${n === 1 ? 'key' : 'keys'} (#${first}${n > 1 ? ` to #${last}` : ''}): ${out}`);
  } else if (cmd === 'check') {
    const serial = check(arg);
    console.log(serial === null ? 'Not a good key.' : `Good key, #${serial}.`);
    process.exitCode = serial === null ? 1 : 0;
  } else {
    console.log('Use: init | batch <n> | key | check <key>');
    process.exitCode = 1;
  }
}

try { main(process.argv.slice(2)); } catch (e) { console.error(e.message); process.exitCode = 1; }
