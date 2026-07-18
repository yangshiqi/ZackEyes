// Single source of truth for the public ZackEyes release that every page
// (download / changelog / docs / answers / index / SEO surfaces) and the
// site-contract tests pull from. Bump this file when a new ZackEyes DMG
// ships on yangshiqi/ZackEyes-release; nothing else under src/ should
// hard-code the version, hash, or size.

export const appVersion = '0.9.2';
export const releaseName = `ZackEyes ${appVersion}`;

// DMG metadata — pulled from `shasum -a 256` and `stat -f%z` against the
// published asset. Verified at release time against the public download.
// `downloadSize` is in decimal MB (10^6 bytes), matching macOS Finder's
// file-size display since 10.6; `downloadSizeLabel` and the bytes label
// derive from it so the bump script only has to rewrite the primitives.
export const downloadBytes = 4038136;
export const downloadSize = '4.0 MB';
export const downloadSizeLabel = `${downloadSize} DMG`;
export const downloadBytesLabel = `${downloadBytes.toLocaleString('en-US')} bytes`;
export const downloadSha256 = '299059a78cc903f451e0d8a86eb74856eb71661101c3365525367495d4a9069b';

// URLs.
//
// Public-channel split (intentional):
// - `yangshiqi/ZackEyes-release` is the user-facing distribution mirror.
//   That's where the DMG lives and where non-developer users file bug
//   reports — keeps the source repo's Releases page clean and keeps the
//   download/issues UX one click away from snapallx-style end users.
// - `yangshiqi/ZackEyes` is the open-source source repo (MIT, monorepo
//   with the website under `website/`). Source-code-curious visitors and
//   would-be contributors land here.
export const downloadUrl = `https://github.com/yangshiqi/ZackEyes-release/releases/download/v${appVersion}/ZackEyes-${appVersion}.dmg`;
export const releasesUrl = 'https://github.com/yangshiqi/ZackEyes-release/releases';
export const issuesUrl = 'https://github.com/yangshiqi/ZackEyes-release/issues';
export const sourceUrl = 'https://github.com/yangshiqi/ZackEyes';
export const contributeUrl = `${sourceUrl}/contribute`;
export const licenseUrl = `${sourceUrl}/blob/master/LICENSE`;
