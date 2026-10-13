#!/usr/bin/env node
// Built-page check for the help article clip (#3703). Runs from `npm run check:help` after `npm run build`.
//
// check-help-content.mjs (prebuild) proves the SOURCE fields obey the contract and the files exist.
// Nothing else looked at what the template renders, so a template edit that stopped emitting the
// <video>, or emitted it with autoplay, would pass every other check. This reads dist/ for every help
// article: one that declares a clip must render exactly the contract's markup, and one that does not
// must render no <video>.
import fs from 'node:fs';
import path from 'node:path';
import { checkRenderedMedia, frontmatterBlock, readMediaFields } from './help-media-contract.mjs';

const root = process.cwd();
const sourceDir = path.join(root, 'src/content/help');
const dist = path.join(root, 'dist');

if (!fs.existsSync(dist)) {
  console.error('FAIL: dist missing, run `npm run build` first.');
  process.exit(1);
}
const articles = fs.existsSync(sourceDir) ? fs.readdirSync(sourceDir).filter((f) => f.endsWith('.md')) : [];
if (articles.length === 0) {
  console.error('FAIL: no help articles found in src/content/help');
  process.exit(1);
}

const problems = [];
let withClip = 0;
let withoutClip = 0;
for (const file of articles) {
  const slug = file.replace(/\.md$/, '');
  const source = fs.readFileSync(path.join(sourceDir, file), 'utf8');
  const block = frontmatterBlock(source);
  const { fields } = block === null ? { fields: {} } : readMediaFields(block);
  const page = path.join(dist, 'help', slug, 'index.html');
  if (!fs.existsSync(page)) {
    problems.push(`${slug}: built page is missing (${path.relative(root, page)})`);
    continue;
  }
  for (const p of checkRenderedMedia(fs.readFileSync(page, 'utf8'), fields)) problems.push(`${slug}: ${p}`);
  if (fields.video === undefined) {
    withoutClip++;
    continue;
  }
  withClip++;
  for (const name of ['video', 'videoPoster']) {
    const built = path.join(dist, fields[name].replace(/^\//, ''));
    if (!fs.existsSync(built) || !fs.statSync(built).isFile()) problems.push(`${slug}: ${fields[name]} is not in dist/`);
  }
}

// Fail closed: a run that checked no clip at all is a vacuous pass, not a clean one.
if (withClip === 0) problems.push('no help article declares a clip, so nothing was checked (expected at least push-to-talk-mode)');

for (const p of problems) console.error(`FAIL: ${p}`);
console.log(`help media: ${articles.length} articles, ${withClip} with a clip, ${withoutClip} without, ${problems.length} problem(s)`);
process.exit(problems.length ? 1 : 0);
