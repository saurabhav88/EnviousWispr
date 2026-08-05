#!/usr/bin/env node
// Search assertions, run against the SHIPPED src/utils/help-search.ts and the
// SHIPPED dist/help-search-index.json. Nothing here reconstructs the field
// boosts or the eligibility rule: a test that rebuilds the configuration tests
// a copy of the search rather than the search.
//
// Run after `npm run build`, so the corpus it reads is the one that ships.
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const root = process.cwd();
const corpusPath = path.join(root, 'dist/help-search-index.json');
if (!fs.existsSync(corpusPath)) {
  console.error('FAIL: dist/help-search-index.json missing — run `npm run build` first.');
  process.exit(1);
}

const { buildHelpIndex, searchHelp } = await import(
  pathToFileURL(path.join(root, 'src/utils/help-search.ts')).href
);

const docs = JSON.parse(fs.readFileSync(corpusPath, 'utf8'));
if (docs.length === 0) {
  console.error('FAIL: search corpus is empty.');
  process.exit(1);
}
const mini = buildHelpIndex(docs);

// The ten queries a real person types, pinned in the plan BEFORE they were
// measured. Four share no meaningful words with their article's title.
const PINNED = [
  ['microphone not working', 'empty-or-missing-transcription'],
  ['how do I change the key', 'customizing-your-hotkey'],
  ['is this free', 'is-enviouswispr-free'],
  ['uninstall', 'uninstalling-enviouswispr'],
  ['airpods', 'bluetooth-and-airpods'],
  ['stop capitalising', 'how-text-gets-pasted-into-your-app'],
  ['paste not working', 'paste-not-working'],
  ['turn off ai', 'choosing-an-ai-provider-none-apple-intelligence-ollama-openai-gemini'],
  ['custom words', 'adding-custom-words'],
  ['does it send my text anywhere', 'ai-polish-and-cloud-data'],
];

// Competing intents. Each row pins the winner AND an article that must NOT win,
// which is the half a single-target test omits.
const ADVERSARIAL = [
  ['which microphone should i use', 'choosing-your-microphone', ['empty-or-missing-transcription']],
  ['change microphone', 'choosing-your-microphone', ['empty-or-missing-transcription']],
  ['airpods sound muffled', 'bluetooth-and-airpods', ['choosing-your-microphone', 'noise-suppression']],
  ['it overwrote my clipboard', 'clipboard-preservation', ['paste-not-working']],
  ['extra space before my text', 'how-text-gets-pasted-into-your-app', ['paste-not-working']],
  ['set up apple intelligence', 'apple-intelligence-setup', ['apple-intelligence-not-available']],
  ['apple intelligence greyed out', 'apple-intelligence-not-available', ['apple-intelligence-setup']],
  ['is my text sent to openai', 'ai-polish-and-cloud-data', ['api-key-security', 'privacy-overview']],
  ['change my hotkey', 'customizing-your-hotkey', ['push-to-talk-mode', 'toggle-mode']],
  ['dont want to hold the key', 'hands-free-mode-long-dictation', ['customizing-your-hotkey']],
  ['unins', 'uninstalling-enviouswispr', []],
  ['not working paste', 'paste-not-working', []],
];

const OFFTOPIC = ['how do i print a document', 'buy a new macbook', 'reset my iphone'];
const TYPOS = ['acessibility', 'blutooth airpods', 'micraphone not workin', 'unistall', 'clipbord', 'apple inteligence'];

let pass = 0;
const failures = [];
const t = (ok, label, detail = '') => (ok ? pass++ : failures.push(`${label} ${detail}`));

for (const [q, want] of PINNED) {
  const { results } = searchHelp(mini, q);
  t(results[0]?.id === want, `pinned "${q}"`, `-> ${results[0]?.id ?? '(none)'}, wanted ${want}`);
}
for (const [q, want, mustNot] of ADVERSARIAL) {
  const { results } = searchHelp(mini, q);
  const first = results[0]?.id;
  t(first === want && !mustNot.includes(first), `adversarial "${q}"`, `-> ${first ?? '(none)'}, wanted ${want}`);
}
// An off-topic query must never claim an EXACT match. Anything it surfaces is
// labelled "closest" in the UI, which is honest rather than confident.
for (const q of OFFTOPIC) {
  const { matchKind } = searchHelp(mini, q);
  t(matchKind !== 'exact', `off-topic "${q}"`, `-> ${matchKind}`);
}
// Ordinary misspellings resolve at tier 1, never via the fallback.
for (const q of TYPOS) {
  const { matchKind, results } = searchHelp(mini, q);
  t(matchKind === 'exact' && results.length > 0, `typo "${q}"`, `-> ${matchKind}`);
}

// The eligibility RULE itself, on synthetic documents, so each clause is tested
// in isolation rather than inferred from corpus behaviour.
{
  const doc = (id, field, value) => ({
    id, title: '', keywords: '', headings: '', description: '', body: '',
    category: 'x', categoryLabel: 'X', section: '', [field]: value,
  });
  const kind = (docs, q) => searchHelp(buildHelpIndex(docs), q).matchKind;
  t(kind([doc('a', 'keywords', 'zebrafish')], 'zebrafish quokka') === 'closest', 'rule: exact curated token unlocks closest');
  t(kind([doc('a', 'keywords', 'zebrafishery')], 'zebrafish quokka') === 'none', 'rule: prefix-only does NOT unlock');
  t(kind([doc('a', 'keywords', 'zebrafish')], 'zebrafisk quokka') === 'none', 'rule: fuzzy-only does NOT unlock');
  t(kind([doc('a', 'body', 'zebrafish in prose')], 'zebrafish quokka') === 'none', 'rule: body-only does NOT unlock');
  const both = searchHelp(buildHelpIndex([doc('a', 'keywords', 'zebrafish'), doc('b', 'body', 'zebrafish prose')]), 'zebrafish quokka');
  t(both.results.length === 1 && both.results[0].id === 'a', 'rule: a curated hit in A never admits body-only B');
}

// Causality control: the hand-authored synonyms must be doing real work. If a
// future edit guts them, this fails loudly instead of search degrading quietly.
{
  const stripped = buildHelpIndex(docs.map((d) => ({ ...d, keywords: '' })));
  let hitsWithout = 0;
  for (const [q, want] of PINNED) {
    if (searchHelp(stripped, q).results[0]?.id === want) hitsWithout++;
  }
  t(hitsWithout < PINNED.length, 'control: removing keywords measurably degrades search', `-> ${hitsWithout}/${PINNED.length} still hit`);
}

for (const f of failures) console.error(`FAIL: ${f}`);
console.log(`help search: ${pass} passed, ${failures.length} failed`);
process.exit(failures.length ? 1 : 0);
