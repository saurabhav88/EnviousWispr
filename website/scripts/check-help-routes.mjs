#!/usr/bin/env node
// Route-SET equality plus a sitemap-date check, against the built output.
//
// Set equality, never a count: one missing route and one unexpected route still
// total 65, so a count reports the same number for a correct build and a broken
// one. The expected set is derived independently from the sources rather than
// from the build, or it would just be agreeing with itself.
import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const SITE = 'https://enviouswispr.com';
const dist = path.join(root, 'dist');
const helpDist = path.join(dist, 'help');

if (!fs.existsSync(helpDist)) {
  console.error('FAIL: dist/help missing — run `npm run build` first.');
  process.exit(1);
}

// Expected, from the sources.
const catSource = fs.readFileSync(path.join(root, 'src/data/help-categories.ts'), 'utf8');
const categories = [...catSource.matchAll(/^\s*slug: '([a-z0-9-]+)',$/gm)].map((m) => m[1]);
const articles = fs
  .readdirSync(path.join(root, 'src/content/help'))
  .filter((f) => f.endsWith('.md'))
  .map((f) => f.replace(/\.md$/, ''));

if (categories.length === 0 || articles.length === 0) {
  console.error(`FAIL: derived 0 categories or 0 articles — the source parse is broken, not the build.`);
  process.exit(1);
}

const expected = new Set(['/help/', ...categories.map((c) => `/help/${c}/`), ...articles.map((a) => `/help/${a}/`)]);

// Built, from dist.
const built = new Set();
(function walk(dir, prefix) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) walk(path.join(dir, entry.name), `${prefix}${entry.name}/`);
    else if (entry.name === 'index.html') built.add(prefix);
  }
})(helpDist, '/help/');

const missing = [...expected].filter((u) => !built.has(u)).sort();
const unexpected = [...built].filter((u) => !expected.has(u)).sort();

// Sitemap: every help URL present exactly once, with a real date, and never
// today-by-default. `updated` may legitimately be today, so this asserts
// presence and uniqueness rather than trying to distinguish the value.
const sitemapFiles = fs.readdirSync(dist).filter((f) => /^sitemap-\d+\.xml$/.test(f));
const xml = sitemapFiles.map((f) => fs.readFileSync(path.join(dist, f), 'utf8')).join('');
const sitemapEntries = [...xml.matchAll(/<loc>([^<]+)<\/loc>\s*<lastmod>([^<]+)<\/lastmod>/g)];
const helpEntries = sitemapEntries.filter(([, loc]) => loc.startsWith(`${SITE}/help/`) || loc === `${SITE}/help/`);
const seen = new Map();
for (const [, loc, lastmod] of helpEntries) seen.set(loc, (seen.get(loc) ?? 0) + 1);

const sitemapMissing = [...expected].filter((u) => !seen.has(`${SITE}${u}`)).sort();
const duplicated = [...seen.entries()].filter(([, n]) => n > 1).map(([u]) => u);
const undated = helpEntries.filter(([, , d]) => !/^\d{4}-\d{2}-\d{2}/.test(d)).map(([, u]) => u);

// Every internal /help/ link in the built pages must resolve. Nine of these
// are inline cross-references inside article prose ("See <Article>"), which the
// Crisp source rendered as italic text with no destination — a reader was told
// where to go and given no way to get there. They are links now, and this is
// what stops a future edit quietly recreating a dead end.
const deadLinks = [];
let linksChecked = 0;
for (const route of built) {
  const file = path.join(dist, route.replace(/^\//, ''), 'index.html');
  if (!fs.existsSync(file)) continue;
  const html = fs.readFileSync(file, 'utf8');
  for (const m of html.matchAll(/href="(\/help\/[a-z0-9-]+\/)"/g)) {
    linksChecked++;
    if (!fs.existsSync(path.join(dist, m[1].replace(/^\//, ''), 'index.html'))) {
      deadLinks.push(`${route} -> ${m[1]}`);
    }
  }
}

// Em and en dashes, checked on the BUILT pages rather than the sources.
//
// check-help-content.mjs already scans article Markdown, but the layer above it
// was uncovered: an em dash written into a layout, a component, or a JSON-LD
// string reaches every page it renders and no source check was looking. One did
// — the category structured-data name, on all twelve category pages, which is
// exactly the kind of string that surfaces in a search result.
//
// The build is the right place to look because it is the only place that sees
// every contributor at once, and because code COMMENTS (which may use dashes)
// never survive into it.
const dashed = [];
for (const route of built) {
  const file = path.join(dist, route.replace(/^\//, ''), 'index.html');
  if (!fs.existsSync(file)) continue;
  const html = fs.readFileSync(file, 'utf8');
  const hits = [...html.matchAll(/[^<>]{0,40}[—–][^<>]{0,40}/g)].map((m) => m[0].trim());
  if (hits.length) dashed.push(`${route}: ${hits.slice(0, 2).join(' | ')}`);
}

const problems = [];
if (dashed.length) problems.push(`em/en dash in built help pages (global Rule 6): ${dashed.join(' ;; ')}`);
if (linksChecked === 0) problems.push('no internal help links found at all — the link scan is broken, not the pages');
if (deadLinks.length) problems.push(`internal help links pointing nowhere: ${deadLinks.join(', ')}`);
if (missing.length) problems.push(`routes missing from the build: ${missing.join(', ')}`);
if (unexpected.length) problems.push(`routes built but not expected: ${unexpected.join(', ')}`);
if (sitemapMissing.length) problems.push(`help URLs absent from the sitemap: ${sitemapMissing.join(', ')}`);
if (duplicated.length) problems.push(`help URLs appearing more than once in the sitemap: ${duplicated.join(', ')}`);
if (undated.length) problems.push(`help URLs with an unparseable lastmod: ${undated.join(', ')}`);

console.log(`help routes: expected ${expected.size}, built ${built.size}, in sitemap ${seen.size}, internal links ${linksChecked} (${deadLinks.length} dead)`);
for (const p of problems) console.error(`FAIL: ${p}`);
process.exit(problems.length ? 1 : 0);
