#!/usr/bin/env node
// Build-output weight check, against dist/. Two things the audit of
// 2026-09-13 found and that nothing else would catch again:
//
// 1. Unreferenced files in /_astro. An eager import.meta.glob over
//    src/assets/home once made Vite emit every full-size illustration master
//    (14 MB) that no page referenced. Every hashed asset must be referenced by
//    at least one html, css or js file, or it is dead weight in every deploy.
// 2. Any single emitted file over the ceiling. The largest legitimate asset
//    today is the founder video at ~2.1 MB; a 1.9 MB illustration master is
//    the failure this guards against, so the ceiling sits just above the video.
import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const dist = path.join(root, 'dist');
const CEILING_BYTES = 2.5 * 1024 * 1024;
const problems = [];

if (!fs.existsSync(dist)) {
  console.error('FAIL: dist missing, run `npm run build` first.');
  process.exit(1);
}

function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(p, out);
    else out.push(p);
  }
  return out;
}

const files = walk(dist);
const referencing = files.filter((f) => /\.(html|css|js|json|xml|txt)$/.test(f));
const corpus = referencing.map((f) => fs.readFileSync(f, 'utf8')).join('\n');

const astroDir = path.join(dist, '_astro');
const hashed = fs.existsSync(astroDir) ? walk(astroDir) : [];
let unreferencedBytes = 0;
for (const f of hashed) {
  const name = path.basename(f);
  if (!corpus.includes(name)) {
    const size = fs.statSync(f).size;
    unreferencedBytes += size;
    problems.push(`unreferenced asset: _astro/${name} (${(size / 1024).toFixed(0)} KB)`);
  }
}

for (const f of files) {
  const size = fs.statSync(f).size;
  if (size > CEILING_BYTES) {
    problems.push(`over ceiling: ${path.relative(dist, f)} (${(size / 1024 / 1024).toFixed(2)} MB > ${CEILING_BYTES / 1024 / 1024} MB)`);
  }
}

const total = files.reduce((n, f) => n + fs.statSync(f).size, 0);
for (const p of problems) console.error(`FAIL: ${p}`);
console.log(
  `dist weight: ${files.length} files, ${(total / 1024 / 1024).toFixed(1)} MB, ${hashed.length} hashed assets, ${(unreferencedBytes / 1024 / 1024).toFixed(1)} MB unreferenced, ${problems.length} problem(s)`,
);
process.exit(problems.length ? 1 : 0);
