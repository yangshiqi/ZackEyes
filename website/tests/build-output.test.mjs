import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { describe, it } from 'node:test';

const root = process.cwd();
const dist = join(root, 'dist');
const hasBuild = existsSync(join(dist, 'index.html'));

describe('production output budgets', { skip: !hasBuild }, () => {
  it('renders the homepage without generated client JavaScript bundles', () => {
    const html = readFileSync(join(dist, 'index.html'), 'utf8');
    const astroDir = join(dist, '_astro');
    const emittedAssets = existsSync(astroDir) ? readdirSync(astroDir) : [];

    assert.doesNotMatch(html, /<script[^>]+type="module"/);
    assert.deepEqual(emittedAssets.filter((file) => file.endsWith('.js')), []);
  });

  it('emits canonical and sitemap URLs on the live origin', () => {
    const html = readFileSync(join(dist, 'index.html'), 'utf8');
    assert.match(html, /rel="canonical" href="https:\/\/zackeyes\.vercel\.app\//);
    assert.doesNotMatch(html, /zackeyes\.app/);

    const sitemap = readFileSync(join(dist, 'sitemap-0.xml'), 'utf8');
    assert.match(sitemap, /https:\/\/zackeyes\.vercel\.app\//);
    assert.doesNotMatch(sitemap, /https:\/\/zackeyes\.app\//);
  });

  it('keeps HTML and CSS inside static landing page budgets', () => {
    const astroDir = join(dist, '_astro');
    const cssFile = existsSync(astroDir) ? readdirSync(astroDir).find((file) => file.endsWith('.css')) : null;
    const htmlBytes = statSync(join(dist, 'index.html')).size;
    const cssBytes = cssFile ? statSync(join(astroDir, cssFile)).size : 0;

    // 31 KB ceiling: the homepage product-screenshot section now carries four
    // real captures (dual-agent, terminal handoff, Settings, attention-first)
    // with accessible image metadata. Keep this tight enough to catch
    // accidental React islands, generated JS bundles, or large inline blobs
    // while allowing real static marketing content to ship.
    assert.ok(htmlBytes < 31_000, `index.html is ${htmlBytes} bytes`);
    assert.ok(cssFile, 'Expected a generated CSS asset in dist/_astro');
    assert.ok(cssBytes < 35_000, `homepage CSS is ${cssBytes} bytes`);
  });
});
