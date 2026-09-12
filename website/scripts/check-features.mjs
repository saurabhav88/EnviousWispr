#!/usr/bin/env node
// Features launch check (#2816), against the built output. Same shape as
// check-help-routes.mjs: the expected set is derived from the source catalog,
// never from the build, and every problem is reported before exiting.
//
// It asserts, for the nine launch URLs in src/data/site-navigation.js:
//   - the built launch routes (everything under /features/ plus /why-offline/
//     and /customization/) equal the catalog exactly, both ways;
//   - every internal link inside those pages resolves to a built route or a
//     fragment on the same page (same-site absolute or relative, fragment aware);
//   - no em or en dash in their HTML;
//   - one <h1>, a canonical, a title of 50 to 60 characters, a description of
//     145 to 155 characters, and WebPage or CollectionPage JSON-LD;
//   - no "Loading" placeholder survives in the built HTML;
//   - every hashed asset a launch page or its JS chunks reference under
//     /_astro/ exists in dist;
//   - the sitemap lists each launch URL exactly once with the catalog's date;
//   - /how-it-works/ is not built, no built page links to it, and _redirects
//     carries its 301 and no /features shadow;
//   - the homepage header and footer link to every launch destination.
import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const SITE = 'https://enviouswispr.com';
const dist = path.join(root, 'dist');

if (!fs.existsSync(dist)) {
  console.error('FAIL: dist missing, run `npm run build` first.');
  process.exit(1);
}

// Expected, from the source catalog.
const catalogSource = fs.readFileSync(path.join(root, 'src/data/site-navigation.js'), 'utf8');
const expected = new Map();
for (const m of catalogSource.matchAll(/path:\s*'([^']+)',[\s\S]*?updated:\s*'(\d{4}-\d{2}-\d{2})'/g)) {
  expected.set(m[1], m[2]);
}
if (expected.size === 0) {
  console.error('FAIL: parsed 0 catalog entries from site-navigation.js; the source parse is broken, not the build.');
  process.exit(1);
}
const isLaunchRoute = (route) => route.startsWith('/features/') || route === '/why-offline/' || route === '/customization/';

// Built routes, from dist.
const builtAll = new Set();
(function walk(dir, prefix) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) walk(path.join(dir, entry.name), `${prefix}${entry.name}/`);
    else if (entry.name === 'index.html') builtAll.add(prefix);
  }
})(dist, '/');
const builtLaunch = new Set([...builtAll].filter(isLaunchRoute));
const missing = [...expected.keys()].filter((u) => !builtLaunch.has(u)).sort();
const unexpected = [...builtLaunch].filter((u) => !expected.has(u)).sort();

const problems = [];
const htmlOf = (route) => fs.readFileSync(path.join(dist, route.replace(/^\//, ''), 'index.html'), 'utf8');
const routeExists = (route) => fs.existsSync(path.join(dist, route.replace(/^\//, ''), 'index.html'));

// Per-page checks.
let linksChecked = 0;
for (const route of [...expected.keys()].filter((r) => builtLaunch.has(r))) {
  const html = htmlOf(route);
  const tag = (name, attr) => html.match(new RegExp(`<${name}[^>]*\\b${attr}="([^"]*)"`, 'i'))?.[1];
  const title = html.match(/<title>([^<]*)<\/title>/)?.[1] ?? '';
  const description = html.match(/<meta name="description" content="([^"]*)"/)?.[1] ?? '';
  const canonical = html.match(/<link rel="canonical" href="([^"]*)"/)?.[1];
  const h1s = (html.match(/<h1[\s>]/g) ?? []).length;
  const ld = [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].map((m) => m[1]);
  const types = ld.flatMap((j) => [...j.matchAll(/"@type":\s*"([A-Za-z]+)"/g)].map((m) => m[1]));
  if (title.length < 50 || title.length > 60) problems.push(`${route}: title is ${title.length} chars, want 50 to 60: "${title}"`);
  if (description.length < 145 || description.length > 155)
    problems.push(`${route}: description is ${description.length} chars, want 145 to 155`);
  if (canonical !== `${SITE}${route}`) problems.push(`${route}: canonical is ${canonical ?? 'missing'}`);
  if (h1s !== 1) problems.push(`${route}: ${h1s} <h1> elements`);
  if (!types.includes('WebPage') && !types.includes('CollectionPage')) problems.push(`${route}: no WebPage or CollectionPage JSON-LD`);
  if (!types.includes('BreadcrumbList')) problems.push(`${route}: no BreadcrumbList JSON-LD`);
  if (/<meta name="robots" content="[^"]*noindex/.test(html)) problems.push(`${route}: noindex`);
  if (/>Loading\b|Loading transcript|Loading…/.test(html)) problems.push(`${route}: a "Loading" placeholder survives in the built HTML`);
  const dashes = [...html.matchAll(/[^<>]{0,40}[—–][^<>]{0,40}/g)].map((m) => m[0].trim());
  if (dashes.length) problems.push(`${route}: em/en dash in built HTML: ${dashes.slice(0, 2).join(' | ')}`);
  void tag;

  // Internal links: same-site absolute, relative, or fragment.
  for (const m of html.matchAll(/href="([^"]+)"/g)) {
    let href = m[1];
    if (/^(https?:)?\/\//.test(href) && !href.startsWith(SITE)) continue;
    if (/^(mailto:|tel:|javascript:)/.test(href)) continue;
    if (href.startsWith(SITE)) href = href.slice(SITE.length);
    linksChecked++;
    const [pathPart, fragment] = href.split('#');
    if (pathPart === '' || pathPart === undefined) {
      if (fragment && !new RegExp(`id="${fragment}"`).test(html)) problems.push(`${route}: fragment #${fragment} not on the page`);
      continue;
    }
    const resolved = pathPart.startsWith('/') ? pathPart : path.posix.normalize(path.posix.join(route, pathPart));
    if (/\.[a-z0-9]+$/i.test(resolved)) {
      if (!fs.existsSync(path.join(dist, resolved))) problems.push(`${route}: file link ${resolved} not in dist`);
      continue;
    }
    const routeForm = resolved.endsWith('/') ? resolved : `${resolved}/`;
    if (!routeExists(routeForm)) problems.push(`${route}: link ${href} resolves to no built route`);
    else if (fragment && !new RegExp(`id="${fragment}"`).test(htmlOf(routeForm)))
      problems.push(`${route}: link ${href} points at a fragment the target lacks`);
  }
}
if (builtLaunch.size && linksChecked === 0) problems.push('no internal links found in launch pages; the link scan is broken, not the pages');

// Hashed assets referenced by launch pages and their JS chunks must exist.
const astroDir = path.join(dist, '_astro');
const referencedAssets = new Set();
const collect = (text) => {
  for (const m of text.matchAll(/\/_astro\/[A-Za-z0-9._-]+\.[a-z0-9]+/g)) referencedAssets.add(m[0]);
};
for (const route of builtLaunch) collect(htmlOf(route));
if (fs.existsSync(astroDir)) {
  for (const file of fs.readdirSync(astroDir)) if (file.endsWith('.js')) collect(fs.readFileSync(path.join(astroDir, file), 'utf8'));
}
for (const asset of referencedAssets) {
  if (!fs.existsSync(path.join(dist, asset))) problems.push(`referenced asset missing from dist: ${asset}`);
}

// Sitemap: each launch URL exactly once, with the catalog's date.
const sitemapFiles = fs.readdirSync(dist).filter((f) => /^sitemap-\d+\.xml$/.test(f));
const xml = sitemapFiles.map((f) => fs.readFileSync(path.join(dist, f), 'utf8')).join('');
const entries = [...xml.matchAll(/<loc>([^<]+)<\/loc>\s*<lastmod>([^<]+)<\/lastmod>/g)];
const seen = new Map();
for (const [, loc, lastmod] of entries) {
  const list = seen.get(loc) ?? [];
  list.push(lastmod.slice(0, 10));
  seen.set(loc, list);
}
for (const [route, date] of expected) {
  const dates = seen.get(`${SITE}${route}`);
  if (!dates) problems.push(`sitemap: ${route} absent`);
  else if (dates.length !== 1) problems.push(`sitemap: ${route} listed ${dates.length} times`);
  else if (dates[0] !== date) problems.push(`sitemap: ${route} lastmod ${dates[0]}, catalog says ${date}`);
}
if (seen.has(`${SITE}/how-it-works/`)) problems.push('sitemap: /how-it-works/ is still listed');

// Retirement: not built, not linked, redirected, and no /features shadow.
if (builtAll.has('/how-it-works/')) problems.push('/how-it-works/ is still built');
const linkers = [];
for (const route of builtAll) {
  if (/href="(https:\/\/enviouswispr\.com)?\/how-it-works\/?"/.test(htmlOf(route))) linkers.push(route);
}
if (linkers.length) problems.push(`built pages still link to /how-it-works/: ${linkers.slice(0, 8).join(', ')}${linkers.length > 8 ? ', …' : ''}`);
const redirects = fs.readFileSync(path.join(root, 'public/_redirects'), 'utf8');
if (!/^\/how-it-works\/ \/features\/ 301$/m.test(redirects)) problems.push('_redirects: /how-it-works/ -> /features/ 301 missing');
if (/^\/features\/? /m.test(redirects)) problems.push('_redirects: a /features rule would shadow the built page');

// Homepage chrome reaches every launch destination.
if (builtAll.has('/')) {
  const home = htmlOf('/');
  const header = home.match(/<header class="site-chrome site-header[\s\S]*?<\/header>/)?.[0] ?? '';
  const footer = home.match(/<footer class="site-chrome site-footer[\s\S]*?<\/footer>/)?.[0] ?? '';
  const chrome = header + footer;
  if (!chrome) problems.push('homepage: shared header/footer markup not found');
  for (const route of expected.keys()) {
    if (!chrome.includes(`href="${route}"`)) problems.push(`homepage chrome does not link to ${route}`);
  }
}

if (missing.length) problems.push(`launch routes missing from the build: ${missing.join(', ')}`);
if (unexpected.length) problems.push(`launch routes built but not in the catalog: ${unexpected.join(', ')}`);

console.log(
  `features: catalog ${expected.size}, built ${builtLaunch.size}, links checked ${linksChecked}, hashed assets referenced ${referencedAssets.size}`,
);
for (const p of problems) console.error(`FAIL: ${p}`);
process.exit(problems.length ? 1 : 0);
