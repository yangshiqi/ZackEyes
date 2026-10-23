import assert from 'node:assert/strict';
import { test } from 'node:test';
import { codexResetVersion, isCodexResetReleased } from '../src/lib/product-plans.mjs';

test('Codex reset release copy follows the published version', () => {
  assert.equal(codexResetVersion, '0.10.2');
  assert.equal(isCodexResetReleased('0.10.1'), false);
  assert.equal(isCodexResetReleased('0.10.2'), true);
  assert.equal(isCodexResetReleased('0.10.3'), true);
  assert.equal(isCodexResetReleased('0.11.0'), true);
});
