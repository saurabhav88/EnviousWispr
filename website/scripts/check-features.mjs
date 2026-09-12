#!/usr/bin/env node
// Features launch check (#2816), against the built output. Same shape as
// check-help-routes.mjs: the expected set is derived from the source catalog,
// never from the build, and every problem is reported before exiting.
//
// Every link, fragment and asset reference is resolved with the URL class
// against the page or chunk that carries it (never path-joined), fragments are
// matched as decoded literal ids, JSON-LD is parsed, and metadata lengths are
// measured after entity decoding.
import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const SITE = 'https://enviouswispr.com';
const dist = path.join(root, 'dist');
const problems = [];

if (!fs.existsSync(dist)) {
  console.error('FAIL: dist missing, run `npm run build` first.');
  process.exit(1);
}

// ── Expected, from the source catalog ──────────────────────────────────────
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

// ── Built pages: every HTML file, including 404.html ───────────────────────
const pages = new Map(); // route or file path → html
(function walk(dir, prefix) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) walk(path.join(dir, entry.name), `${prefix}${entry.name}/`);
    else if (entry.name === 'index.html') pages.set(prefix, fs.readFileSync(path.join(dir, entry.name), 'utf8'));
    else if (entry.name.endsWith('.html')) pages.set(`${prefix}${entry.name}`, fs.readFileSync(path.join(dir, entry.name), 'utf8'));
  }
})(dist, '/');
const builtLaunch = new Set([...pages.keys()].filter(isLaunchRoute));
const missing = [...expected.keys()].filter((u) => !builtLaunch.has(u)).sort();
const unexpected = [...builtLaunch].filter((u) => !expected.has(u)).sort();

// ── Resolution helpers ─────────────────────────────────────────────────────
const decode = (s) =>
  s
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)));
const hasId = (html, id) => {
  const needle = `id="${id.replace(/"/g, '&quot;')}"`;
  return html.includes(needle) || html.includes(`id='${id}'`);
};
/** Resolve an href against the page it sits on. Returns {pathname, hash, external} */
function resolve(href, baseRoute) {
  let url;
  try {
    url = new URL(decode(href), `${SITE}${baseRoute}`);
  } catch {
    return { invalid: true };
  }
  const external = url.origin !== SITE;
  return { url, external, pathname: url.pathname, hash: url.hash ? decodeURIComponent(url.hash.slice(1)) : '' };
}
/** Built HTML for a pathname, whether a route (dir index) or a file. */
function pageFor(pathname) {
  if (pages.has(pathname)) return pages.get(pathname);
  if (!pathname.endsWith('/') && pages.has(`${pathname}/`)) return pages.get(`${pathname}/`);
  return null;
}
function fileExists(pathname) {
  return fs.existsSync(path.join(dist, pathname.replace(/^\//, '')));
}
/** Validate every same-site link on a page; returns the count checked. */
function checkLinks(route, html, label = route) {
  let checked = 0;
  for (const m of html.matchAll(/href="([^"]+)"/g)) {
    const href = m[1];
    if (/^(mailto:|tel:|javascript:)/i.test(href)) continue;
    const r = resolve(href, route);
    if (r.invalid) {
      problems.push(`${label}: unparseable href ${href}`);
      continue;
    }
    if (r.external) continue;
    checked++;
    const target = pageFor(r.pathname);
    if (target) {
      if (r.hash && !hasId(target, r.hash)) problems.push(`${label}: ${href} points at a fragment the target lacks`);
    } else if (/\.[a-z0-9]+$/i.test(r.pathname)) {
      if (!fileExists(r.pathname)) problems.push(`${label}: file link ${href} not in dist`);
    } else {
      problems.push(`${label}: link ${href} resolves to no built route`);
    }
  }
  return checked;
}

// ── Per-launch-page checks ─────────────────────────────────────────────────
let linksChecked = 0;
for (const route of [...expected.keys()].filter((r) => builtLaunch.has(r))) {
  const html = pages.get(route);
  const title = decode(html.match(/<title>([^<]*)<\/title>/)?.[1] ?? '');
  const description = decode(html.match(/<meta name="description" content="([^"]*)"/)?.[1] ?? '');
  const canonical = html.match(/<link rel="canonical" href="([^"]*)"/)?.[1];
  const h1s = (html.match(/<h1[\s>]/g) ?? []).length;
  const types = [];
  for (const m of html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)) {
    try {
      const parsed = JSON.parse(m[1]);
      const walkTypes = (node) => {
        if (Array.isArray(node)) return node.forEach(walkTypes);
        if (node && typeof node === 'object') {
          if (typeof node['@type'] === 'string') types.push(node['@type']);
          for (const v of Object.values(node)) walkTypes(v);
        }
      };
      walkTypes(parsed);
    } catch {
      problems.push(`${route}: JSON-LD block does not parse`);
    }
  }
  const tlen = [...title].length;
  const dlen = [...description].length;
  if (tlen < 50 || tlen > 60) problems.push(`${route}: title is ${tlen} chars, want 50 to 60: "${title}"`);
  if (dlen < 145 || dlen > 155) problems.push(`${route}: description is ${dlen} chars, want 145 to 155`);
  if (canonical !== `${SITE}${route}`) problems.push(`${route}: canonical is ${canonical ?? 'missing'}`);
  if (h1s !== 1) problems.push(`${route}: ${h1s} <h1> elements`);
  if (!types.includes('WebPage') && !types.includes('CollectionPage')) problems.push(`${route}: no WebPage or CollectionPage JSON-LD`);
  if (!types.includes('BreadcrumbList')) problems.push(`${route}: no BreadcrumbList JSON-LD`);
  if (/<meta name="robots" content="[^"]*noindex/.test(html)) problems.push(`${route}: noindex`);
  if (/>Loading\b|Loading transcript|Loading…/.test(html)) problems.push(`${route}: a "Loading" placeholder survives in the built HTML`);
  const dashes = [...html.matchAll(/[^<>]{0,40}[—–][^<>]{0,40}/g)].map((m) => m[0].trim());
  if (dashes.length) problems.push(`${route}: em/en dash in built HTML: ${dashes.slice(0, 2).join(' | ')}`);
  linksChecked += checkLinks(route, html);
}
if (builtLaunch.size && linksChecked === 0) problems.push('no internal links found in launch pages; the link scan is broken, not the pages');

// ── Hashed assets reachable from launch pages ──────────────────────────────
// Follow each page's stylesheets, scripts and modulepreloads, then the
// relative and absolute references inside every reached JS/CSS file. Every
// reference must resolve to a file in dist.
const visitedAssets = new Set();
let assetsChecked = 0;
function checkAsset(pathname, from) {
  if (visitedAssets.has(pathname)) return;
  visitedAssets.add(pathname);
  assetsChecked++;
  const file = path.join(dist, pathname.replace(/^\//, ''));
  if (!fs.existsSync(file)) {
    problems.push(`asset missing from dist: ${pathname} (referenced by ${from})`);
    return;
  }
  if (!/\.(js|mjs|css)$/.test(pathname)) return;
  const text = fs.readFileSync(file, 'utf8');
  const refs = [
    ...[...text.matchAll(/import\(\s*["']([^"']+)["']\s*\)/g)].map((m) => m[1]),
    ...[...text.matchAll(/from\s*["']([^"']+)["']/g)].map((m) => m[1]),
    ...[...text.matchAll(/new URL\(\s*["']([^"']+)["']\s*,\s*import\.meta\.url\s*\)/g)].map((m) => m[1]),
    ...[...text.matchAll(/url\(\s*["']?([^"')]+)["']?\s*\)/g)].map((m) => m[1]),
    ...[...text.matchAll(/["'](\/_astro\/[^"']+)["']/g)].map((m) => m[1]),
  ];
  for (const ref of refs) {
    if (/^(data:|https?:|\/\/|#)/.test(ref)) continue;
    const r = resolve(ref, pathname);
    if (r.invalid || r.external) continue;
    checkAsset(r.pathname, pathname);
  }
}
for (const route of builtLaunch) {
  const html = pages.get(route);
  for (const m of html.matchAll(/<(?:link|script)[^>]*\b(?:href|src)="([^"]+)"/g)) {
    const r = resolve(m[1], route);
    if (r.invalid || r.external) continue;
    if (r.pathname.startsWith('/_astro/') || /\.(js|mjs|css|json|wav|mp3|webp|png|svg)$/.test(r.pathname)) checkAsset(r.pathname, route);
  }
  for (const m of html.matchAll(/\b(?:src|href|data-src|data-transcript)="(\/_astro\/[^"]+)"/g)) checkAsset(m[1], route);
}

// ── Sitemap: every launch URL exactly once, with the catalog's date ────────
const sitemapFiles = fs.readdirSync(dist).filter((f) => /^sitemap-\d+\.xml$/.test(f));
const xml = sitemapFiles.map((f) => fs.readFileSync(path.join(dist, f), 'utf8')).join('');
const seen = new Map();
for (const m of xml.matchAll(/<url>([\s\S]*?)<\/url>/g)) {
  const loc = m[1].match(/<loc>([^<]+)<\/loc>/)?.[1];
  const lastmod = m[1].match(/<lastmod>([^<]+)<\/lastmod>/)?.[1] ?? null;
  if (!loc) continue;
  const list = seen.get(loc) ?? [];
  list.push(lastmod ? lastmod.slice(0, 10) : null);
  seen.set(loc, list);
}
for (const [route, date] of expected) {
  const dates = seen.get(`${SITE}${route}`);
  if (!dates) problems.push(`sitemap: ${route} absent`);
  else if (dates.length !== 1) problems.push(`sitemap: ${route} listed ${dates.length} times`);
  else if (dates[0] !== date) problems.push(`sitemap: ${route} lastmod ${dates[0] ?? 'missing'}, catalog says ${date}`);
}
if (seen.has(`${SITE}/how-it-works/`) || seen.has(`${SITE}/how-it-works`)) problems.push('sitemap: /how-it-works/ is still listed');

// ── Retirement: not built, not linked (any form, any fragment), redirected ─
if (pages.has('/how-it-works/')) problems.push('/how-it-works/ is still built');
const linkers = [];
for (const [route, html] of pages) {
  for (const m of html.matchAll(/href="([^"]+)"/g)) {
    const r = resolve(m[1], route.endsWith('.html') ? '/' : route);
    if (!r.invalid && !r.external && /^\/how-it-works\/?$/.test(r.pathname)) {
      linkers.push(route);
      break;
    }
  }
}
if (linkers.length) problems.push(`built pages still link to /how-it-works/: ${linkers.slice(0, 8).join(', ')}${linkers.length > 8 ? ', …' : ''}`);
const redirects = fs.readFileSync(path.join(root, 'public/_redirects'), 'utf8');
for (const form of ['/how-it-works', '/how-it-works/']) {
  if (!new RegExp(`^${form.replace(/\//g, '\\/')} \\/features\\/ 301$`, 'm').test(redirects)) problems.push(`_redirects: ${form} -> /features/ 301 missing`);
}
if (/^\/features\/? /m.test(redirects)) problems.push('_redirects: a /features rule would shadow the built page');

// ── Homepage: shell present, every ordinary link valid, chrome reaches launch ─
const home = pages.get('/');
if (!home) problems.push('homepage index.html is missing from the build');
else {
  const header = home.match(/<header class="site-chrome chrome-header[\s\S]*?<\/header>/)?.[0];
  const footer = home.match(/<footer class="site-chrome chrome-footer[\s\S]*?<\/footer>/)?.[0];
  if (!header) problems.push('homepage: shared header markup not found');
  if (!footer) problems.push('homepage: shared footer markup not found');
  for (const route of expected.keys()) {
    if (header && !header.includes(`href="${route}"`)) problems.push(`homepage header does not link to ${route}`);
  }
  for (const route of ['/features/', '/why-offline/', '/customization/']) {
    if (footer && !footer.includes(`href="${route}"`)) problems.push(`homepage footer does not link to ${route}`);
  }
  linksChecked += checkLinks('/', home, 'homepage');
}

if (missing.length) problems.push(`launch routes missing from the build: ${missing.join(', ')}`);
if (unexpected.length) problems.push(`launch routes built but not in the catalog: ${unexpected.join(', ')}`);

console.log(
  `features: catalog ${expected.size}, built ${builtLaunch.size}, links checked ${linksChecked}, assets reached ${assetsChecked}, pages scanned ${pages.size}`,
);
for (const p of problems) console.error(`FAIL: ${p}`);
process.exit(problems.length ? 1 : 0);
