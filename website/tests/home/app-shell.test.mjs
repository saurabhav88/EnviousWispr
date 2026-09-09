import test from 'node:test';
import assert from 'node:assert/strict';
import { renderHost } from '../../src/utils/home/app-shell.js';
import { renderDraft, renderTokens } from '../../src/utils/home/text.js';

// Protect the shared server/client insertion boundary, not a screenshot snapshot.
test('all approved host apps expose exactly one draft insertion point', () => {
  for (const app of [
    'gmail',
    'claude',
    'slack',
    'whatsapp',
    'vscode',
    'clinical',
    'keep',
    'docs',
    'discord',
    'notes',
    'teams',
  ]) {
    const html = renderHost(app);
    assert.equal((html.match(/class="host-draft-slot(?: |")/g) || []).length, 1, app);
  }
});
test('missing context retains authored defaults instead of printing undefined', () => {
  assert.match(renderHost('slack', { room: undefined }), /# team-updates/);
  assert.match(renderHost('gmail', { to: undefined, subject: null }), /Maya/);
  assert.doesNotMatch(renderHost('gmail', { to: undefined, subject: null }), /undefined|null/);
});
test('context and draft content cannot become executable markup', () => {
  const payload = '<img src=x onerror=alert(1)>';
  assert.doesNotMatch(renderHost('gmail', { to: payload }), /<img src=x/);
  assert.match(renderDraft(payload), /&lt;img/);
  assert.doesNotMatch(renderTokens([{ t: payload, cut: true }]), /<img src=x/);
});
