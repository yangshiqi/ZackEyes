import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, it } from 'node:test';
import {
  appVersion,
  releaseName,
  downloadUrl,
  issuesUrl,
  downloadSha256,
  downloadSize,
  downloadSizeLabel,
  downloadBytes,
  downloadBytesLabel
} from '../src/lib/release.mjs';

const root = process.cwd();
const publicPagePaths = [
  'src/pages/index.astro',
  'src/pages/docs.astro',
  'src/pages/changelog.astro',
  'src/pages/roadmap.astro',
  'src/pages/answers.astro',
  'src/pages/security.astro',
  'src/pages/download.astro',
  'src/pages/privacy.astro'
];

function read(path) {
  return readFileSync(join(root, path), 'utf8');
}

describe('Astro site contract', () => {
  it('uses the reference Astro static stack', () => {
    assert.equal(existsSync(join(root, 'astro.config.mjs')), true);
    assert.equal(existsSync(join(root, 'src/pages/index.astro')), true);
    assert.equal(existsSync(join(root, 'src/layouts/SiteLayout.astro')), true);
    assert.equal(existsSync(join(root, 'src/styles/global.css')), true);

    const pkg = JSON.parse(read('package.json'));
    assert.match(pkg.dependencies.astro, /^\^5\./);
    assert.match(pkg.dependencies.react, /^\^19\./);
    assert.match(pkg.dependencies.tailwindcss, /^\^4\./);

    const astroConfig = read('astro.config.mjs');
    // 'directory' (Astro default) emits /foo/index.html so Vercel can serve
    // /foo without an .html → clean URL redirect. Pairing with the explicit
    // `trailingSlash: 'never'` keeps the sitemap and canonical tags
    // emitting /foo (no trailing slash) — matching the site's nav hrefs.
    assert.match(astroConfig, /build:\s*\{[\s\S]*?format:\s*['"]directory['"]/s);
    assert.match(astroConfig, /trailingSlash:\s*['"]never['"]/);
    assert.match(astroConfig, /@astrojs\/sitemap/);
    assert.match(astroConfig, /@tailwindcss\/vite/);
  });

  it('ships SEO and GEO discovery surfaces', () => {
    assert.equal(existsSync(join(root, 'public/robots.txt')), true);
    assert.equal(existsSync(join(root, 'public/site.webmanifest')), true);
    assert.equal(existsSync(join(root, 'public/logo-symbol.svg')), true);
    assert.equal(existsSync(join(root, 'src/pages/llms.txt.ts')), true);
    assert.equal(existsSync(join(root, 'src/pages/llms-full.txt.ts')), true);

    const layout = read('src/layouts/SiteLayout.astro');
    assert.match(layout, /<title>\{title\}<\/title>/);
    assert.match(layout, /name="description"/);
    assert.match(layout, /rel="canonical"/);
    assert.match(layout, /property="og:title"/);
    assert.match(layout, /name="twitter:card"/);
    assert.match(layout, /application\/ld\+json/);
    assert.match(layout, /SoftwareApplication/);

    const llms = read('src/pages/llms.txt.ts');
    assert.match(llms, /ZackEyes/);
    assert.match(llms, /Claude Code/);
    assert.match(llms, /Codex CLI/);
  });

  it('uses one shared top navigation across all public pages', () => {
    assert.equal(existsSync(join(root, 'src/components/SiteHeader.astro')), true);

    const header = read('src/components/SiteHeader.astro');
    for (const href of ['/#control', '/#agents', '/docs', '/changelog', '/roadmap', '/answers', '/security', '/#faq', '/privacy', '/download']) {
      assert.match(header, new RegExp(`href="${href.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"`));
    }
    assert.match(header, /href="\/download" aria-label="Open ZackEyes download page"/);

    for (const path of publicPagePaths) {
      const page = read(path);
      assert.match(page, /import SiteHeader from '\.\.\/components\/SiteHeader\.astro';/);
      assert.match(page, /<SiteHeader \/>/);
      assert.doesNotMatch(page, /<header class="topbar">/);
    }
  });

  it('uses one shared footer across all public pages', () => {
    assert.equal(existsSync(join(root, 'src/components/SiteFooter.astro')), true);

    const footer = read('src/components/SiteFooter.astro');
    for (const href of ['/docs', '/changelog', '/roadmap', '/answers', '/security', '/privacy', '/download']) {
      assert.match(footer, new RegExp(`href="${href.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"`));
    }
    assert.match(footer, /Claude Code \+ Codex CLI/);

    for (const path of publicPagePaths) {
      const page = read(path);
      assert.match(page, /import SiteFooter from '\.\.\/components\/SiteFooter\.astro';/);
      assert.match(page, /<SiteFooter \/>/);
      assert.doesNotMatch(page, /<footer class="footer">/);
    }
  });

  it('keeps the homepage fast to open and render', () => {
    const page = read('src/pages/index.astro');
    const css = read('src/styles/global.css');

    assert.doesNotMatch(page, /client:(load|idle|visible|media|only)/);
    assert.match(page, /<canvas class="cosmos"/);
    assert.match(page, /const ctx = canvas instanceof HTMLCanvasElement \? canvas\.getContext\("2d"\) : null;/);
    assert.match(page, /if \(ctx && canvas && story\) \{/);
    assert.match(page, /requestAnimationFrame/);
    assert.match(page, /document\.hidden/);
    assert.match(page, /requestIdleCallback/);
    assert.match(page, /window\.setTimeout\(callback, 16\)/);
    assert.match(page, /IntersectionObserver/);
    assert.match(page, /Cap links to bound draws\./);
    assert.match(page, /prefers-reduced-motion/);
    assert.match(css, /content-visibility:\s*auto/);
    assert.match(css, /font-display:\s*swap/);
    assert.doesNotMatch(css, /@import\s+url\(/);
    assert.doesNotMatch(css, /backdrop-filter/);
    assert.doesNotMatch(css, /mix-blend-mode/);
    assert.doesNotMatch(css, /\.device\s*\{[^}]*animation:/s);
    assert.doesNotMatch(css, /\.island\s*\{[^}]*animation:/s);
    assert.doesNotMatch(css, /\.device\s*\{[^}]*will-change:/s);
    assert.doesNotMatch(css, /\.island\s*\{[^}]*will-change:/s);
  });

  it('preserves the product story in semantic sections', () => {
    const page = read('src/pages/index.astro');

    assert.match(page, /<h1>\s*<span>Your AI agents<\/span>\s*<span class="accent">in the notch\.<\/span>\s*<\/h1>/s);
    assert.match(page, /Claude Code/);
    assert.match(page, /Codex CLI/);
    assert.match(page, /Permission prompts without context switching/);
    assert.match(page, /Rate limits where they matter/);
    assert.match(page, /Multiple themes/);
    assert.match(page, /Display modes for real notches, simulated islands, menu bar use, and external displays/);
    assert.match(page, /Rock Legends/);
    assert.match(page, /F1 2026/);
    assert.match(page, /AI moguls/);
    assert.match(page, /Jump to the right terminal tab/);
    assert.match(page, /iTerm2/);
    assert.match(page, /Ghostty/);
    assert.match(page, /Warp/);
    assert.match(page, /Kitty/);
    assert.match(page, /Alacritty/);
    assert.match(page, /VS Code/);
    assert.match(page, /Cursor/);
    assert.match(page, /Context window usage/);
    assert.match(page, /model and cost/);
    assert.match(page, /custom global hotkey/);
    assert.match(page, /in-app DMG download/);
    assert.match(page, /Unix sockets/);
    // Release metadata is sourced from src/lib/release.mjs — verify the
    // page imports it and consumes the symbols rather than re-asserting
    // the literal version / hash / size strings (those move with each
    // release and are covered by the "release metadata" test below).
    assert.match(page, /from '\.\.\/lib\/release\.mjs'/);
    assert.match(page, /\bappVersion\b/);
    assert.match(page, /\breleaseName\b/);
    assert.match(page, /\bdownloadUrl\b/);
    assert.match(page, /\bissuesUrl\b/);
    assert.match(page, /\bdownloadSizeLabel\b/);
    assert.match(page, /\bdownloadSha256\b/);
    assert.match(page, /href=\{downloadUrl\}>Download for macOS/);
    assert.match(page, /href=\{downloadUrl\} aria-label=\{`Download \$\{releaseName\} for macOS`\}>Download ZackEyes <span aria-hidden="true">↓<\/span><\/a>/);
    assert.match(page, /href=\{issuesUrl\} aria-label="Open ZackEyes issues and feature requests on GitHub">Issues & requests <span aria-hidden="true">↗<\/span><\/a>/);
    assert.match(page, /\{releaseName\}/);
  });

  it('release metadata is centralised in src/lib/release.mjs', () => {
    assert.equal(existsSync(join(root, 'src/lib/release.mjs')), true);

    // Constants must form a self-consistent set: appVersion drives the
    // download URL, downloadBytes drives the comma-formatted label.
    assert.match(appVersion, /^\d+\.\d+\.\d+$/);
    assert.equal(releaseName, `ZackEyes ${appVersion}`);
    assert.equal(
      downloadUrl,
      `https://github.com/yangshiqi/ZackEyes-release/releases/download/v${appVersion}/ZackEyes-${appVersion}.dmg`
    );
    assert.match(downloadSha256, /^[0-9a-f]{64}$/);
    assert.equal(typeof downloadBytes, 'number');
    assert.ok(downloadBytes > 0);
    assert.equal(downloadBytesLabel, `${downloadBytes.toLocaleString('en-US')} bytes`);
    assert.match(downloadSize, /^[\d.]+ MB$/);
    assert.equal(downloadSizeLabel, `${downloadSize} DMG`);

    // No other source file should hard-code the version / URL / hash —
    // each page must import from the central lib.
    const sourcesToScan = [
      'src/pages/index.astro',
      'src/pages/download.astro',
      'src/pages/changelog.astro',
      'src/pages/docs.astro',
      'src/pages/answers.astro',
      'src/pages/privacy.astro',
      'src/pages/roadmap.astro',
      'src/pages/security.astro',
      'src/pages/llms.txt.ts',
      'src/pages/llms-full.txt.ts',
      'src/layouts/SiteLayout.astro'
    ];
    for (const path of sourcesToScan) {
      if (!existsSync(join(root, path))) continue;
      const src = read(path);
      assert.doesNotMatch(
        src,
        /releases\/download\/v\d+\.\d+\.\d+\/ZackEyes-\d+\.\d+\.\d+\.dmg/,
        `${path} hard-codes a download URL — import downloadUrl from ../lib/release.mjs instead`
      );
      assert.doesNotMatch(
        src,
        /[0-9a-f]{64}/,
        `${path} hard-codes a SHA256 — import downloadSha256 from ../lib/release.mjs instead`
      );
    }
  });

  it('publishes a product roadmap', () => {
    assert.equal(existsSync(join(root, 'src/pages/roadmap.astro')), true);

    const page = read('src/pages/roadmap.astro');
    assert.match(page, /Roadmap/);
    assert.match(page, /More agent support/);
    assert.match(page, /Richer task state/);
    assert.match(page, /Custom notifications/);
    assert.match(page, /Codex hook compatibility/);
    assert.match(page, /ItemList/);
  });

  it('publishes release notes and update history', () => {
    assert.equal(existsSync(join(root, 'src/pages/changelog.astro')), true);

    const page = read('src/pages/changelog.astro');
    assert.match(page, /ZackEyes 0\.4\.2/);
    assert.match(page, /Published May 16, 2026/);
    assert.match(page, /Codex popup context usage fixes/);
    assert.match(page, /Notification noise reduction/);
    assert.match(page, /ZackEyes 0\.3\.2/);
    assert.match(page, /Codex session state fixes/);
    assert.match(page, /Per-agent recency windows/);
    assert.match(page, /Both agents in one notch/);
    assert.match(page, /In-app DMG download/);
    assert.match(page, /release\.highlights\.map/);
    assert.match(page, /GitHub Releases/);
    assert.match(page, /ItemList/);
    // downloadUrl/sha256/size are imported from ../lib/release.mjs; verify
    // the page consumes those symbols rather than the literal values.
    assert.match(page, /from '\.\.\/lib\/release\.mjs'/);
    assert.match(page, /\{downloadUrl\}/);
  });

  it('documents install, uninstall, and compatibility requirements', () => {
    assert.equal(existsSync(join(root, 'src/pages/docs.astro')), true);

    const page = read('src/pages/docs.astro');
    assert.match(page, /Install ZackEyes/);
    assert.match(page, /Uninstall ZackEyes/);
    assert.match(page, /Troubleshooting/);
    assert.match(page, /macOS says ZackEyes cannot be opened/);
    assert.match(page, /Claude or Codex sessions do not appear/);
    assert.match(page, /Permission requests do not show in the notch/);
    assert.match(page, /Reinstall hooks/);
    assert.match(page, /macOS 14/);
    assert.match(page, /Apple Silicon/);
    assert.match(page, /Intel/);
    assert.match(page, /Claude Code/);
    assert.match(page, /Codex CLI/);
    assert.match(page, /Accessibility permission/);
    assert.match(page, /Notifications permission/);
    assert.match(page, /iTerm2/);
    assert.match(page, /Terminal\.app/);
    assert.match(page, /Ghostty/);
    assert.match(page, /Change Hotkey/);
    assert.match(page, /Show Dynamic Island/);
    assert.match(page, /Compact display/);
    assert.match(page, /HowTo/);
    assert.match(page, /TechArticle/);
    assert.match(page, /from '\.\.\/lib\/release\.mjs'/);
    assert.match(page, /\{downloadUrl\}/);
  });

  it('publishes a dedicated download page with verification metadata', () => {
    assert.equal(existsSync(join(root, 'src/pages/download.astro')), true);

    const page = read('src/pages/download.astro');
    assert.match(page, /Download ZackEyes/);
    assert.match(page, /macOS 14/);
    assert.match(page, /Apple Silicon \+ Intel/);
    assert.match(page, /Multiple themes/);
    assert.match(page, /Rock Legends/);
    assert.match(page, /F1 2026/);
    assert.match(page, /AI moguls/);
    assert.match(page, /custom notification sounds/);
    assert.match(page, /terminal tab jump/);
    assert.match(page, /custom global hotkey/);
    // Version / size / hash / URL are read from ../lib/release.mjs.
    assert.match(page, /from '\.\.\/lib\/release\.mjs'/);
    assert.match(page, /\{releaseName\}/);
    assert.match(page, /\{downloadSize\}/);
    assert.match(page, /\{downloadBytesLabel\}/);
    assert.match(page, /\{downloadSha256\}/);
    assert.match(page, /\{downloadUrl\}/);
    assert.match(page, /\{issuesUrl\}/);
    assert.match(page, /SoftwareApplication/);
    assert.match(page, /HowTo/);
  });

  it('publishes the local security and safety model', () => {
    assert.equal(existsSync(join(root, 'src/pages/security.astro')), true);

    const page = read('src/pages/security.astro');
    assert.match(page, /Security and safety model/);
    assert.match(page, /local-first/);
    assert.match(page, /Unix socket/);
    assert.match(page, /~\/\.claude\/settings\.json/);
    assert.match(page, /~\/\.codex\/hooks\.json/);
    assert.match(page, /timestamped backup/);
    assert.match(page, /zackeyes/);
    assert.match(page, /never read or write `~\/\.codex\/config\.toml`/);
    assert.match(page, /fail quietly/);
    assert.match(page, /exits 0/);
    assert.match(page, /TechArticle/);
  });

  it('answers common buyer questions with FAQ schema', () => {
    const page = read('src/pages/index.astro');

    assert.match(page, /<section class="faq-band" id="faq"/);
    assert.match(page, /Frequently asked questions/);
    assert.match(page, /Which macOS versions does ZackEyes support\?/);
    assert.match(page, /Does ZackEyes collect my code or agent prompts\?/);
    assert.match(page, /Where should I report bugs or feature requests\?/);
    assert.match(page, /Does ZackEyes work on Macs without a notch\?/);
    assert.match(page, /Does ZackEyes work with external displays\?/);
    assert.match(page, /Why does ZackEyes write Claude and Codex hooks\?/);
    assert.match(page, /What happens if ZackEyes is closed\?/);
    // FAQ structured data references the SHA256 via the imported variable.
    assert.match(page, /\{downloadSha256\}/);
    assert.match(page, /FAQPage/);
    assert.match(page, /mainEntity/);
    assert.match(page, /Question/);
    assert.match(page, /Answer/);
  });

  it('documents local-first privacy expectations', () => {
    assert.equal(existsSync(join(root, 'src/pages/privacy.astro')), true);

    const page = read('src/pages/privacy.astro');
    assert.match(page, /Local-first by default/);
    assert.match(page, /ZackEyes does not require an account/);
    assert.match(page, /does not upload your source code/);
    assert.match(page, /Analytics/);
    assert.match(page, /Network requests/);
    assert.match(page, /Local files and settings/);
    assert.match(page, /Delete local data/);
    assert.match(page, /GitHub Releases/);
    assert.match(page, /GitHub Issues/);
    assert.match(page, /PrivacyPolicy/);
  });

  it('publishes direct answer content for AI discovery', () => {
    assert.equal(existsSync(join(root, 'src/pages/answers.astro')), true);

    const page = read('src/pages/answers.astro');
    assert.match(page, /Direct answers/);
    assert.match(page, /What is ZackEyes\?/);
    assert.match(page, /Is ZackEyes local-first\?/);
    assert.match(page, /Does ZackEyes support Codex CLI\?/);
    assert.match(page, /Which terminals can ZackEyes jump to\?/);
    assert.match(page, /Does ZackEyes support themes and notification sounds\?/);
    assert.match(page, /How do I install ZackEyes\?/);
    assert.match(page, /Where do I report ZackEyes issues\?/);
    assert.match(page, /FAQPage/);
  });

  it('uses the themed Z arrow logo symbol', () => {
    const header = read('src/components/SiteHeader.astro');
    const logo = read('public/logo-symbol.svg');
    const icon = read('public/icon.svg');
    const readme = read('README.md');

    assert.match(header, /src="\/logo-symbol\.svg"/);
    assert.match(logo, /Letter Z Logo Design with Arrow/);
    assert.match(logo, /#b7ff4a/);
    assert.match(logo, /#5be7ff/);
    assert.match(icon, /#050605/);
    assert.match(icon, /#b7ff4a/);
    assert.match(readme, /Logo source: `https:\/\/www\.logosymbol\.com\/letter\/letter-z-logo-design-with-arrow`/);
  });

  it('exposes release and feedback links for LLM-readable discovery', () => {
    const llms = read('src/pages/llms.txt.ts');
    const llmsFull = read('src/pages/llms-full.txt.ts');

    // Both LLM endpoints import release metadata from ../lib/release.mjs
    // and interpolate it into the response body.
    assert.match(llms, /from '\.\.\/lib\/release\.mjs'/);
    assert.match(llms, /\$\{downloadUrl\}/);
    assert.match(llms, /\$\{issuesUrl\}/);
    assert.match(llms, /\$\{downloadSha256\}/);
    assert.match(llms, /macOS 14/);
    assert.match(llms, /Apple Silicon/);
    assert.match(llms, /Intel/);
    assert.match(llms, /Privacy/);
    assert.match(llms, /Download/);
    assert.match(llms, /Security and safety model/);
    assert.match(llms, /Multiple themes/);
    assert.match(llms, /terminal tab jump/);
    assert.match(llms, /Rock Legends/);
    assert.match(llms, /F1 2026/);
    assert.match(llms, /AI moguls/);
    assert.match(llms, /Roadmap/);
    assert.match(llms, /Direct answers/);
    assert.match(llmsFull, /from '\.\.\/lib\/release\.mjs'/);
    assert.match(llmsFull, /\$\{downloadUrl\}/);
    assert.match(llmsFull, /\$\{issuesUrl\}/);
    assert.match(llmsFull, /\$\{downloadSha256\}/);
    assert.match(llmsFull, /\$\{releaseName\}/);
    assert.match(llmsFull, /Install/);
    assert.match(llmsFull, /Uninstall/);
    assert.match(llmsFull, /Compatibility/);
    assert.match(llmsFull, /Local files and settings/);
    assert.match(llmsFull, /Troubleshooting/);
    assert.match(llmsFull, /Download page/);
    assert.match(llmsFull, /Security and safety model/);
    assert.match(llmsFull, /Multiple themes/);
    assert.match(llmsFull, /terminal tab jump/);
    assert.match(llmsFull, /custom notification sounds/);
    assert.match(llmsFull, /context window usage/);
    assert.match(llmsFull, /Unix socket/);
    assert.match(llmsFull, /Roadmap/);
    assert.match(llmsFull, /Direct answers/);
  });

  it('documents the website information architecture in README', () => {
    const readme = read('README.md');

    assert.match(readme, /\/docs/);
    assert.match(readme, /\/changelog/);
    assert.match(readme, /\/roadmap/);
    assert.match(readme, /\/answers/);
    assert.match(readme, /\/security/);
    assert.match(readme, /\/download/);
    assert.match(readme, /\/privacy/);
    assert.match(readme, /SiteFooter\.astro/);
    assert.match(readme, /Multiple themes/);
    assert.match(readme, /Rock Legends/);
    assert.match(readme, /terminal tab jump/);
    assert.match(readme, /context window usage/);
    assert.match(readme, /DMG size/);
    assert.match(readme, /SHA256/);
    assert.match(readme, new RegExp(downloadSha256));
  });

  it('keeps production output tests defensive', () => {
    const test = read('tests/build-output.test.mjs');

    assert.match(test, /const cssFile = existsSync\(astroDir\)/);
    assert.match(test, /cssFile \? statSync\(join\(astroDir, cssFile\)\)\.size : 0/);
  });
});
