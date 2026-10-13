#!/usr/bin/env node
// Content rules for help articles. Runs from `npm run build` via prebuild, so
// it executes in CI on every deploy.
//
// Replaces scripts/kb-lint.sh, which was gitignored, ran against JSON that no
// longer exists, and only ever ran when a human remembered. Same checks, moved
// to where forgetting is impossible.
//
// Zod already rejects missing or malformed frontmatter and an unknown category,
// so this file carries only the checks that need the BODY, which a collection
// schema cannot see, plus the clip contract (#3703), which needs the files on disk.
import fs from 'node:fs';
import path from 'node:path';
import { validateMedia } from './help-media-contract.mjs';

const DIR = path.join(process.cwd(), 'src/content/help');
const PUBLIC_DIR = path.join(process.cwd(), 'public');

// Internal symbol names that must never reach a reader. Carried over verbatim
// from the deleted kb-lint.sh.
const JARGON = [
  'XPC', 'CGEvent', 'AXTextField', 'AXTextArea', 'AXComboBox', 'AXSearchField',
  'AXUIElement', 'PreRollForwarder', 'CaptureRouteResolver', 'WordCorrectionStep',
  'WordCorrector', 'RegisterEventHotKey', 'feedAudio', 'TCC (',
];

// kb-lint.sh checked for the &mdash; / &ndash; ENTITIES, the only form that can
// appear in JSON. Markdown holds the literal characters, so the check has to
// widen or it silently stops working. Global Rule 6.
const DASHES = [
  ['—', 'em dash'],
  ['–', 'en dash'],
  ['&mdash;', 'em dash entity'],
  ['&ndash;', 'en dash entity'],
];

const errors = [];

const files = fs.existsSync(DIR) ? fs.readdirSync(DIR).filter((f) => f.endsWith('.md')) : [];

// Fail CLOSED. An empty directory is a broken build, not a clean run — the same
// failure shape as a residue grep that returns nothing because the path is wrong.
if (files.length === 0) {
  console.error('FAIL: no help articles found in src/content/help');
  process.exit(1);
}

for (const file of files) {
  const raw = fs.readFileSync(path.join(DIR, file), 'utf8');
  const body = raw.replace(/^---\n[\s\S]*?\n---\n/, '');

  errors.push(...validateMedia(file, raw, PUBLIC_DIR));

  for (const term of JARGON) {
    if (body.includes(term)) errors.push(`${file}: internal jargon "${term}"`);
  }
  for (const [ch, label] of DASHES) {
    if (body.includes(ch)) errors.push(`${file}: ${label} (global Rule 6)`);
  }
  // Apple Intelligence polish needs macOS 26, not 15.1. This has been wrong in
  // our copy before, which is why it is an error rather than a warning.
  if (/macOS 15\.1/.test(body)) {
    errors.push(`${file}: says "macOS 15.1" for Apple Intelligence (it is macOS 26)`);
  }
}

for (const e of errors) console.error(`FAIL: ${e}`);
console.log(`help content: ${files.length} articles, ${errors.length} error(s)`);
process.exit(errors.length ? 1 : 0);
