#!/usr/bin/env node
// Rewrite `src/lib/release.mjs` with new version/hash/size metadata. Used
// by `.github/workflows/bump-version.yml`, which is triggered by
// `make release` over in the ccisland repo after it has uploaded a new
// DMG to yangshiqi/ZackEyes-release.
//
// Usage:
//   node scripts/bump-release.mjs \
//     --version 0.4.4 \
//     --sha256 <64 hex chars> \
//     --bytes <integer>

import { readFileSync, writeFileSync } from 'node:fs';
import { argv, exit } from 'node:process';

function arg(flag) {
  const i = argv.indexOf(flag);
  if (i < 0 || i === argv.length - 1) {
    console.error(`missing ${flag}`);
    exit(1);
  }
  return argv[i + 1];
}

const version = arg('--version');
const sha256 = arg('--sha256');
const bytesRaw = arg('--bytes');

if (!/^\d+\.\d+\.\d+$/.test(version)) {
  console.error(`bad --version: ${version}`);
  exit(1);
}
if (!/^[0-9a-f]{64}$/.test(sha256)) {
  console.error(`bad --sha256: ${sha256}`);
  exit(1);
}
const bytes = Number(bytesRaw);
if (!Number.isInteger(bytes) || bytes <= 0) {
  console.error(`bad --bytes: ${bytesRaw}`);
  exit(1);
}

// "2.8 MB DMG" — one decimal place. macOS Finder shows the same
// rounding (binary MB), and the tests assert on this exact format.
const sizeMb = (bytes / 1024 / 1024).toFixed(1);
const sizeLabel = `${sizeMb} MB DMG`;

const path = 'src/lib/release.mjs';
const before = readFileSync(path, 'utf8');

function replaceOrFail(src, label, pattern, replacement) {
  if (!pattern.test(src)) {
    console.error(`could not find ${label} in ${path}; pattern: ${pattern}`);
    exit(1);
  }
  return src.replace(pattern, replacement);
}

let after = before;
after = replaceOrFail(
  after, 'appVersion',
  /(export const appVersion = ')[^']+(';)/,
  `$1${version}$2`
);
after = replaceOrFail(
  after, 'downloadBytes',
  /(export const downloadBytes = )\d+(;)/,
  `$1${bytes}$2`
);
after = replaceOrFail(
  after, 'downloadSizeLabel',
  /(export const downloadSizeLabel = ')[^']+(';)/,
  `$1${sizeLabel}$2`
);
after = replaceOrFail(
  after, 'downloadSha256',
  /(export const downloadSha256 = ')[^']+(';)/,
  `$1${sha256}$2`
);

if (after === before) {
  console.log(`release.mjs already at v${version} (${sha256}, ${bytes} bytes) — nothing to do`);
  exit(0);
}

writeFileSync(path, after);
console.log(`bumped release.mjs → v${version} (${sizeLabel}, ${bytes} bytes, sha256 ${sha256})`);
