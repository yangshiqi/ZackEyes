import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, it } from 'node:test';

const root = process.cwd();

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
    assert.match(astroConfig, /build:\s*\{\s*format:\s*['"]file['"]/s);
    assert.match(astroConfig, /@astrojs\/sitemap/);
    assert.match(astroConfig, /@tailwindcss\/vite/);
  });

  it('ships SEO and GEO discovery surfaces', () => {
    assert.equal(existsSync(join(root, 'public/robots.txt')), true);
    assert.equal(existsSync(join(root, 'public/site.webmanifest')), true);
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

  it('keeps the homepage fast to open and render', () => {
    const page = read('src/pages/index.astro');
    const css = read('src/styles/global.css');

    assert.doesNotMatch(page, /client:(load|idle|visible|media|only)/);
    assert.match(page, /<canvas class="cosmos"/);
    assert.match(page, /const ctx = canvas instanceof HTMLCanvasElement \? canvas\.getContext\("2d"\) : null;/);
    assert.match(page, /if \(ctx && canvas && story\) \{/);
    assert.match(page, /requestAnimationFrame/);
    assert.match(page, /document\.hidden/);
    assert.match(page, /prefers-reduced-motion/);
    assert.match(css, /content-visibility:\s*auto/);
    assert.match(css, /font-display:\s*swap/);
    assert.doesNotMatch(css, /@import\s+url\(/);
  });

  it('preserves the product story in semantic sections', () => {
    const page = read('src/pages/index.astro');

    assert.match(page, /<h1>\s*<span>Your AI agents<\/span>\s*<span class="accent">in the notch\.<\/span>\s*<\/h1>/s);
    assert.match(page, /Claude Code/);
    assert.match(page, /Codex CLI/);
    assert.match(page, /Permission prompts without context switching/);
    assert.match(page, /Rate limits where they matter/);
    assert.match(page, /Unix sockets/);
    assert.match(page, /href="#" aria-label="Download ZackEyes for macOS">Download ZackEyes <span aria-hidden="true">↓<\/span><\/a>/);
    assert.match(page, /href="#" aria-label="View ZackEyes source on GitHub">View on GitHub <span aria-hidden="true">↗<\/span><\/a>/);
  });

  it('keeps production output tests defensive', () => {
    const test = read('tests/build-output.test.mjs');

    assert.match(test, /const cssFile = existsSync\(astroDir\)/);
    assert.match(test, /cssFile \? statSync\(join\(astroDir, cssFile\)\)\.size : 0/);
  });
});
