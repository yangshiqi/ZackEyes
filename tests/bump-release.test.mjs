import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { parseNotes } from '../scripts/bump-release.mjs';

describe('parseNotes', () => {
  it('extracts a leading paragraph as summary', () => {
    const out = parseNotes(`Codex fix.\n\n## Fixed\n- foo\n- bar\n`);
    assert.equal(out.summary, 'Codex fix.');
    assert.deepEqual(out.highlights, [
      { label: 'Fixed', items: ['foo', 'bar'] }
    ]);
  });

  it('honours an explicit `Summary:` line', () => {
    const out = parseNotes(`Summary: One sentence.\n\n## Added\n- thing\n`);
    assert.equal(out.summary, 'One sentence.');
    assert.deepEqual(out.highlights, [
      { label: 'Added', items: ['thing'] }
    ]);
  });

  it('joins a multi-line summary paragraph', () => {
    const out = parseNotes(
      `First line.\nSecond line.\n\n## Fixed\n- x\n`
    );
    assert.equal(out.summary, 'First line. Second line.');
    assert.deepEqual(out.highlights, [{ label: 'Fixed', items: ['x'] }]);
  });

  it('accepts plain `Label:` headers in addition to markdown headers', () => {
    const out = parseNotes(
      `Patch.\n\nFixed:\n- a\n- b\n\nAdded:\n- c\n`
    );
    assert.equal(out.summary, 'Patch.');
    assert.deepEqual(out.highlights, [
      { label: 'Fixed', items: ['a', 'b'] },
      { label: 'Added', items: ['c'] }
    ]);
  });

  it('groups stray bullets under a default Notes label', () => {
    const out = parseNotes(`Quick patch.\n\n- one\n- two\n`);
    assert.equal(out.summary, 'Quick patch.');
    assert.deepEqual(out.highlights, [
      { label: 'Notes', items: ['one', 'two'] }
    ]);
  });

  it('returns empty highlights for prose-only notes', () => {
    const out = parseNotes(`Just a sentence about the release.\n`);
    assert.equal(out.summary, 'Just a sentence about the release.');
    assert.deepEqual(out.highlights, []);
  });

  it('treats `*` bullets the same as `-`', () => {
    const out = parseNotes(`Patch.\n\n## Fixed\n* alpha\n* beta\n`);
    assert.deepEqual(out.highlights, [
      { label: 'Fixed', items: ['alpha', 'beta'] }
    ]);
  });

  it('capitalises the label initial', () => {
    const out = parseNotes(`Patch.\n\n## fixed\n- x\n\n## added\n- y\n`);
    assert.deepEqual(out.highlights.map((h) => h.label), ['Fixed', 'Added']);
  });

  it('drops empty groups', () => {
    const out = parseNotes(`Patch.\n\n## Fixed\n\n## Added\n- only here\n`);
    assert.deepEqual(out.highlights, [
      { label: 'Added', items: ['only here'] }
    ]);
  });

  it('handles missing summary gracefully', () => {
    const out = parseNotes(`## Fixed\n- thing\n`);
    assert.equal(out.summary, null);
    assert.deepEqual(out.highlights, [{ label: 'Fixed', items: ['thing'] }]);
  });
});
