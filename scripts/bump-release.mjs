#!/usr/bin/env node
// Rewrite `src/lib/release.mjs` with new version/hash/size metadata, and
// optionally prepend a new entry to `src/pages/changelog.astro` from a
// release-notes file. Used by `.github/workflows/bump-version.yml`,
// which is triggered by `make release` over in the ccisland repo after
// it has uploaded a new DMG to yangshiqi/ZackEyes-release.
//
// Usage:
//   node scripts/bump-release.mjs \
//     --version 0.4.4 \
//     --sha256 <64 hex chars> \
//     --bytes <integer> \
//     [--notes-file <path>] \
//     [--date YYYY-MM-DD]
//
// Notes format (markdown, permissive — see parseNotes below):
//   Optional first paragraph or `Summary:` line → entry summary.
//   `## Label` headers → start a new highlight group.
//   `- item` bullets → push to current group.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { argv, exit } from 'node:process';
import { fileURLToPath } from 'node:url';

// ---------- Main (only when invoked as a script) ----------
//
// Guarded behind `if (process.argv[1] === fileURLToPath(import.meta.url))`
// so the test runner can `import { parseNotes } from '…/bump-release.mjs'`
// without triggering arg parsing or filesystem writes.

if (argv[1] && fileURLToPath(import.meta.url) === argv[1]) {
  main();
}

function main() {
  const version = arg('--version');
  const sha256 = arg('--sha256');
  const bytesRaw = arg('--bytes');
  const notesFile = arg('--notes-file', { required: false });
  const dateOverride = arg('--date', { required: false });

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

  bumpReleaseMjs({ version, sha256, bytes });

  const notesText = readNotes(notesFile);
  if (notesText) {
    const { summary, highlights } = parseNotes(notesText);
    if (!summary && highlights.length === 0) {
      console.log(`notes file ${notesFile} parsed to nothing — skipping changelog`);
    } else {
      updateChangelog({ version, summary, highlights, dateOverride });
    }
  } else if (notesFile) {
    console.log(`notes file ${notesFile} missing or empty — skipping changelog`);
  } else {
    console.log(`no --notes-file — skipping changelog`);
  }
}

function arg(flag, { required = true } = {}) {
  const i = argv.indexOf(flag);
  if (i < 0 || i === argv.length - 1) {
    if (required) {
      console.error(`missing ${flag}`);
      exit(1);
    }
    return null;
  }
  return argv[i + 1];
}

// ---------- release.mjs ----------

function bumpReleaseMjs({ version, sha256, bytes }) {
  // Decimal MB (10^6 bytes), matching what macOS Finder has displayed
  // since 10.6. `downloadSizeLabel` in release.mjs is derived from
  // `downloadSize`, so the script only rewrites the primitive.
  const sizeMb = (bytes / 1_000_000).toFixed(1);
  const size = `${sizeMb} MB`;

  const releasePath = 'src/lib/release.mjs';
  const releaseBefore = readFileSync(releasePath, 'utf8');

  const replace = (src, label, pattern, replacement) => {
    if (!pattern.test(src)) {
      console.error(`could not find ${label} in ${releasePath}; pattern: ${pattern}`);
      exit(1);
    }
    return src.replace(pattern, replacement);
  };

  let releaseAfter = releaseBefore;
  releaseAfter = replace(
    releaseAfter, 'appVersion',
    /(export const appVersion = ')[^']+(';)/,
    `$1${version}$2`
  );
  releaseAfter = replace(
    releaseAfter, 'downloadBytes',
    /(export const downloadBytes = )\d+(;)/,
    `$1${bytes}$2`
  );
  releaseAfter = replace(
    releaseAfter, 'downloadSize',
    /(export const downloadSize = ')[^']+(';)/,
    `$1${size}$2`
  );
  releaseAfter = replace(
    releaseAfter, 'downloadSha256',
    /(export const downloadSha256 = ')[^']+(';)/,
    `$1${sha256}$2`
  );

  if (releaseAfter !== releaseBefore) {
    writeFileSync(releasePath, releaseAfter);
    console.log(`bumped release.mjs → v${version} (${size} DMG, ${bytes} bytes, sha256 ${sha256})`);
  } else {
    console.log(`release.mjs already at v${version} (${sha256}, ${bytes} bytes) — no change`);
  }
}

// ---------- helpers ----------

function readNotes(path) {
  if (!path) return null;
  if (!existsSync(path)) return null;
  const text = readFileSync(path, 'utf8').trim();
  if (!text) return null;
  // Filter out the GitHub-release default placeholder ("Release v0.4.4")
  // so a no-NOTES `make release` doesn't write a content-free changelog
  // entry. Reviewers can still add one by hand on the PR branch.
  if (/^Release v\d+\.\d+\.\d+\s*$/i.test(text)) return null;
  return text;
}

export function parseNotes(text) {
  const rawLines = text.split('\n');
  let summary = null;
  const groups = [];
  let currentGroup = null;
  let collectingSummary = true;

  for (const raw of rawLines) {
    const line = raw.trim();

    if (!line) {
      if (summary) collectingSummary = false;
      continue;
    }

    // Markdown `## Label` (or `# Label`) header
    const headerMatch = line.match(/^#+\s+(.+?)\s*$/);
    if (headerMatch) {
      collectingSummary = false;
      currentGroup = { label: normalizeLabel(headerMatch[1]), items: [] };
      groups.push(currentGroup);
      continue;
    }

    // Plain `Label:` line at column zero (e.g. "Fixed:")
    const labelMatch = line.match(/^([A-Za-z][A-Za-z0-9 /+&-]*):\s*$/);
    if (labelMatch && !line.startsWith('-') && !line.startsWith('*')) {
      const labelKey = labelMatch[1].trim();
      if (collectingSummary && /^summary$/i.test(labelKey)) {
        // "Summary:" alone — next non-empty line is the actual summary.
        continue;
      }
      collectingSummary = false;
      currentGroup = { label: normalizeLabel(labelKey), items: [] };
      groups.push(currentGroup);
      continue;
    }

    // Bullet
    const bulletMatch = line.match(/^[-*]\s+(.+)$/);
    if (bulletMatch) {
      collectingSummary = false;
      if (!currentGroup) {
        currentGroup = { label: 'Notes', items: [] };
        groups.push(currentGroup);
      }
      currentGroup.items.push(bulletMatch[1].trim());
      continue;
    }

    // Anything else — treat as prose. If we're still collecting the
    // summary, append. Otherwise drop (we don't have a place for it).
    if (collectingSummary) {
      const cleaned = line.replace(/^summary:\s*/i, '');
      summary = summary ? `${summary} ${cleaned}` : cleaned;
    }
  }

  const highlights = groups.filter((g) => g.items.length > 0);
  return { summary, highlights };
}

function normalizeLabel(raw) {
  const trimmed = raw.trim().replace(/[.!:]+$/, '');
  if (!trimmed) return 'Notes';
  // Capitalise first letter, leave the rest as the user typed it.
  return trimmed[0].toUpperCase() + trimmed.slice(1);
}

function updateChangelog({ version, summary, highlights, dateOverride }) {
  const path = 'src/pages/changelog.astro';
  const before = readFileSync(path, 'utf8');

  const tag = `ZackEyes ${version}`;
  if (before.includes(`version: '${tag}'`)) {
    console.log(`changelog already has entry for ${tag} — skipping`);
    return;
  }

  const dateLabel = formatDateLabel(dateOverride);
  const entry = renderEntry({ tag, dateLabel, summary, highlights });

  // `\s*` instead of a literal `\n` so the script survives a Prettier
  // pass that drops the trailing newline or normalises whitespace
  // between the `[` and the first entry.
  const arrayStart = before.match(/(const releases = \[\s*)/);
  if (!arrayStart) {
    console.error(`could not find 'const releases = [' in ${path}`);
    exit(1);
  }
  const after = before.replace(arrayStart[1], `${arrayStart[1]}${entry}`);
  writeFileSync(path, after);
  console.log(`prepended changelog entry for ${tag}`);
}

function formatDateLabel(override) {
  // ISO YYYY-MM-DD → "Month Day, Year". UTC by default; matches the
  // existing entries' style ("Published May 18, 2026").
  let d;
  if (override) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(override)) {
      console.error(`bad --date: ${override}`);
      exit(1);
    }
    d = new Date(`${override}T00:00:00Z`);
  } else {
    d = new Date();
  }
  const months = [
    'January','February','March','April','May','June',
    'July','August','September','October','November','December'
  ];
  return `Published ${months[d.getUTCMonth()]} ${d.getUTCDate()}, ${d.getUTCFullYear()}`;
}

function renderEntry({ tag, dateLabel, summary, highlights }) {
  const summaryLine = summary
    ? `    summary: ${jsLit(summary)},\n`
    : '';
  const highlightLines = renderHighlights(highlights);
  return (
    `  {\n` +
    `    version: ${jsLit(tag)},\n` +
    `    date: ${jsLit(dateLabel)},\n` +
    summaryLine +
    `    highlights: [\n${highlightLines}    ]\n` +
    `  },\n`
  );
}

function renderHighlights(highlights) {
  if (highlights.length === 0) {
    // Always emit at least one placeholder group so the page renders
    // a recognisable shape; reviewer can fill it in on the PR branch.
    return (
      `      {\n` +
      `        label: 'Notes',\n` +
      `        items: [\n` +
      `          // TODO: fill in highlights before merging.\n` +
      `        ]\n` +
      `      }\n`
    );
  }
  return highlights
    .map(({ label, items }) => {
      const itemLines = items
        .map((item) => `          ${jsLit(item)}`)
        .join(',\n');
      return (
        `      {\n` +
        `        label: ${jsLit(label)},\n` +
        `        items: [\n${itemLines}\n        ]\n` +
        `      }`
      );
    })
    .join(',\n') + '\n';
}

function jsLit(value) {
  // Emit a single-quoted string. Escape backslashes, single quotes, and
  // any literal newlines (notes content is generally a single line per
  // item, but defensive).
  const escaped = value
    .replace(/\\/g, '\\\\')
    .replace(/'/g, "\\'")
    .replace(/\n/g, '\\n');
  return `'${escaped}'`;
}
