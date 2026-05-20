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

  it('keeps HTML and CSS inside static landing page budgets', () => {
    const astroDir = join(dist, '_astro');
    const cssFile = existsSync(astroDir) ? readdirSync(astroDir).find((file) => file.endsWith('.css')) : null;
    const htmlBytes = statSync(join(dist, 'index.html')).size;
    const cssBytes = cssFile ? statSync(join(astroDir, cssFile)).size : 0;

    // 25.5 KB instead of 25 KB so version bumps that grow the rendered
    // URL (e.g. 0.4.3 → 0.4.10 or 0.10.0) don't blow the budget —
    // ~3-4 occurrences × a couple extra digits adds <100 bytes and was
    // pushing right against the previous ceiling. Still tight enough to
    // catch real bloat (e.g. an accidentally-loaded React island).
    assert.ok(htmlBytes < 25_500, `index.html is ${htmlBytes} bytes`);
    assert.ok(cssFile, 'Expected a generated CSS asset in dist/_astro');
    assert.ok(cssBytes < 35_000, `homepage CSS is ${cssBytes} bytes`);
  });
});
