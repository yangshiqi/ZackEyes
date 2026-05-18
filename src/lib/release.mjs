// Single source of truth for the public ZackEyes release that every page
// (download / changelog / docs / answers / index / SEO surfaces) and the
// site-contract tests pull from. Bump this file when a new ZackEyes DMG
// ships on yangshiqi/ZackEyes-release; nothing else under src/ should
// hard-code the version, hash, or size.

export const appVersion = '0.4.3';
export const releaseName = `ZackEyes ${appVersion}`;

// DMG metadata — pulled from `shasum -a 256` and `stat -f%z` against the
// published asset. Verified at release time against the public download.
// `downloadSize` is in decimal MB (10^6 bytes), matching macOS Finder's
// file-size display since 10.6; `downloadSizeLabel` and the bytes label
// derive from it so the bump script only has to rewrite the primitives.
export const downloadBytes = 2954678;
export const downloadSize = '3.0 MB';
export const downloadSizeLabel = `${downloadSize} DMG`;
export const downloadBytesLabel = `${downloadBytes.toLocaleString('en-US')} bytes`;
export const downloadSha256 = '800ffbbe93cf46c99c3a6111ff03c28c8bac8c93e70200710c1d0f0e0227f18b';

// URLs — public-channel only. The source repo (yangshiqi/ZackEyes) holds
// an empty internal release record; everything user-visible points at the
// release mirror at yangshiqi/ZackEyes-release.
export const downloadUrl = `https://github.com/yangshiqi/ZackEyes-release/releases/download/v${appVersion}/ZackEyes-${appVersion}.dmg`;
export const releasesUrl = 'https://github.com/yangshiqi/ZackEyes-release/releases';
export const issuesUrl = 'https://github.com/yangshiqi/ZackEyes-release/issues';
