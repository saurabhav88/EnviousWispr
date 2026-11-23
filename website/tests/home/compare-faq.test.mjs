import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { faqAnswerHtml, faqAnswerText } from '../../src/utils/compare-faq.js';

const COMPARE_DIR = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../src/pages/compare',
);

test('faqAnswerText and faqAnswerHtml format links, code spans, and escape HTML', () => {
  const sample = 'See [guide](/blog/start/) and `Settings > Engine` with A & B < C.';
  assert.equal(
    faqAnswerText(sample),
    'See guide and Settings > Engine with A & B < C.',
  );
  assert.equal(
    faqAnswerHtml(sample),
    'See <a href="/blog/start/" style="color: var(--accent); text-decoration: underline;">guide</a> and <code>Settings &gt; Engine</code> with A &amp; B &lt; C.',
  );
});

test('all compare pages render FAQs from one source without stale whole-path speed figures', () => {
  const files = fs
    .readdirSync(COMPARE_DIR)
    .filter((f) => f.endsWith('.astro'))
    .sort();
  assert.ok(files.length >= 20, `expected compare pages, saw ${files.length}`);

  for (const file of files) {
    const src = fs.readFileSync(path.join(COMPARE_DIR, file), 'utf8');
    assert.doesNotMatch(src, /0\.61/, `${file}: stale 0.61s latency figure (#3895)`);
    assert.doesNotMatch(src, /1\.65\s*s\b/, `${file}: stale 1.65s whole-path figure (#3895)`);
    assert.doesNotMatch(src, /trailing median/i, `${file}: stale trailing median claim (#3895)`);
    assert.doesNotMatch(
      src,
      /<p class="faq-a">[^<{]/,
      `${file}: hardcoded visible FAQ duplicates JSON-LD source (#3866)`,
    );
  }
});
