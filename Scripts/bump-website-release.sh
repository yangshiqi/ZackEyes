#!/usr/bin/env bash
#
# Bump website/ release metadata locally after a new DMG is built.
#
# Replaces the old cross-repo `gh workflow run bump-version.yml --repo
# yangshiqi/ZackEyes-website` flow. Now that the website lives under
# website/ in this same repo, the bump is done locally and committed
# alongside the Info.plist bump in `make release`.
#
# Usage:
#   ./Scripts/bump-website-release.sh VERSION DMG_PATH [NOTES_FILE]
#
# Example (called from Makefile):
#   ./Scripts/bump-website-release.sh 0.4.5 .build/ZackEyes-0.4.5.dmg /tmp/notes.md
#
# Touches:
#   website/src/lib/release.mjs       (always)
#   website/README.md                 (always)
#   website/src/pages/changelog.astro (only if NOTES_FILE non-empty)
#
# Exits non-zero on any failure — caller decides whether to abort the
# wider release flow.

set -euo pipefail

VERSION="${1:?usage: $0 VERSION DMG_PATH [NOTES_FILE]}"
DMG_PATH="${2:?usage: $0 VERSION DMG_PATH [NOTES_FILE]}"
NOTES_FILE="${3:-}"

if [ ! -f "$DMG_PATH" ]; then
  echo "ERROR: DMG not found at $DMG_PATH" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB_DIR="$REPO_ROOT/website"

if [ ! -d "$WEB_DIR" ]; then
  echo "ERROR: website/ directory missing at $WEB_DIR" >&2
  exit 1
fi

SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
BYTES=$(stat -f%z "$DMG_PATH")

echo "→ Bumping website/ release metadata"
echo "   version: $VERSION"
echo "   sha256:  $SHA256"
echo "   bytes:   $BYTES"

cd "$WEB_DIR"

# Lockfile-faithful install so tests/build run against the pinned tree.
pnpm install --frozen-lockfile

NOTES_FLAG=()
if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ] && [ -s "$NOTES_FILE" ]; then
  NOTES_FLAG=(--notes-file "$NOTES_FILE")
fi

node scripts/bump-release.mjs \
  --version "$VERSION" \
  --sha256 "$SHA256" \
  --bytes "$BYTES" \
  "${NOTES_FLAG[@]}"

echo "→ Verifying site still builds + tests pass"
pnpm run build
pnpm test

echo "✅ website/ updated to v$VERSION"
