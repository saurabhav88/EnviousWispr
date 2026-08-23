import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { run, validateSolutionCluster } from './check-solutions.mjs';

function words(count, offset = 0) {
  return Array.from({ length: count }, (_, index) => `word${index + 1 + offset}`).join(' ');
}

// The shipped layout splits the answer into a lead sentence plus balanced columns, so the
// default fixture is multi-paragraph and the checked count is their SUM.
const answerParagraphs = [words(20), words(60, 20), words(60, 80)];

function prose(paragraphs) {
  return paragraphs === null
    ? '<p>No prose container</p>'
    : `<div data-answer-prose>${paragraphs.map((text) => `<p>${text}</p>`).join('')}</div>`;
}

function page({ route = '/solutions/developers/', title = 'Free Dictation for Developers on Mac | EnviousWispr', description = 'Dictate pull requests, reviews, documentation, and prompts on Mac with free, private, on-device voice input designed for technical vocabulary every day.', source = 'solution-developers', body = answerParagraphs, target = '/solutions/', webPage = true, breadcrumb = true, faq = true, emDash = false, h1Count = 1, canonical = `https://enviouswispr.com${route}`, downloadHref = 'https://example.com/EnviousWispr.dmg', bottomDownload = true } = {}) {
  const heading = `<h1>One heading${emDash ? ' —' : ''}</h1>`;
  return {
    route,
    kind: 'landing',
    html: `<!doctype html><html><head><title>${title}</title><meta name="description" content="${description}"><link rel="canonical" href="${canonical}">${webPage ? '<script type="application/ld+json">{"@type":"WebPage"}</script>' : ''}${breadcrumb ? '<script type="application/ld+json">{"@type":"BreadcrumbList"}</script>' : ''}</head><body>${heading.repeat(h1Count)}<a href="${target}">Solutions</a><a href="${downloadHref}" data-download-source="${source}">Download</a><section data-answer-block><p>Label</p><h2>Answer</h2>${prose(body)}</section>${faq ? '<details><summary>Question</summary><p>Answer</p></details>' : ''}${bottomDownload ? `<a href="${downloadHref}" data-download-source="${source}-bottom">Download</a>` : ''}</body></html>`,
  };
}

function hub({ collectionPage = true, itemList = true } = {}) {
  const collection = collectionPage
    ? (itemList ? '{"@type":"CollectionPage","mainEntity":{"@type":"ItemList"}}' : '{"@type":"CollectionPage"}')
    : '{"@type":"ItemList"}';
  return {
    route: '/solutions/',
    kind: 'hub',
    html: `<!doctype html><html><head><title>Mac Dictation Solutions for Real Work | EnviousWispr</title><meta name="description" content="Find a free Mac dictation workflow for coding, writing, private offline work, and clean AI-polished text. Explore EnviousWispr and download free."><link rel="canonical" href="https://enviouswispr.com/solutions/"><script type="application/ld+json">${collection}</script><script type="application/ld+json">{"@type":"BreadcrumbList"}</script></head><body><h1>One heading</h1><a href="/solutions/developers/">Developers</a></body></html>`,
  };
}

function sitemap(...routes) {
  return routes.map((route) => `<loc>https://enviouswispr.com${route}</loc>`).join('');
}

function writeSource(root, filename) {
  const sourceDir = path.join(root, 'src', 'pages', 'solutions');
  fs.mkdirSync(sourceDir, { recursive: true });
  fs.writeFileSync(path.join(sourceDir, filename), '');
}

function writeBuilt(root, route, html) {
  const file = path.join(root, 'dist', route.replace(/^\//, ''), 'index.html');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, html);
}

// A source/dist tree where every document passes, so each run() test can break exactly one thing.
function validSolutionsTree(root) {
  writeSource(root, 'index.astro');
  writeSource(root, 'developers.astro');
  writeBuilt(root, '/solutions/', hub().html);
  writeBuilt(root, '/solutions/developers/', page().html);
  fs.writeFileSync(path.join(root, 'dist', 'sitemap-0.xml'), sitemap('/solutions/', '/solutions/developers/'));
}

function runQuiet(root) {
  const logs = [];
  const failures = [];
  const originalLog = console.log;
  const originalError = console.error;
  try {
    console.log = (line) => logs.push(String(line));
    console.error = (line) => failures.push(String(line));
    return { exitCode: run(root), logs, failures };
  } finally {
    console.log = originalLog;
    console.error = originalError;
  }
}

test('accepts a complete hub and landing page', () => {
  const documents = [hub(), page()];
  assert.deepEqual(validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) }), []);
});

test('rejects a direct answer outside the extraction window', () => {
  const documents = [hub(), page({ body: ['too short', 'still short'] })];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.ok(errors.some((error) => error.includes('direct answer has 4 words')));
});

test('counts every answer paragraph, not just the last one', () => {
  // The last paragraph alone is 60 words, well under the floor. Only summing clears it,
  // so this fails against a checker that reads a single paragraph.
  const documents = [hub(), page()];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.deepEqual(errors.filter((error) => error.includes('direct answer')), []);
});

test('rejects an answer that was never broken up', () => {
  const documents = [hub(), page({ body: [words(140)] })];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.ok(errors.some((error) => error.includes('direct answer is 1 paragraph(s)')));
});

test('rejects an answer block with no prose container', () => {
  const documents = [hub(), page({ body: null })];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.ok(errors.some((error) => error.includes('no [data-answer-prose] container')));
});

test('rejects a solution link with no built route', () => {
  const documents = [hub(), page({ target: '/solutions/missing/' })];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.ok(errors.some((error) => error.includes('solution link points nowhere')));
});

test('rejects duplicate metadata and download attribution', () => {
  const first = page();
  const second = page({ route: '/solutions/writers/', source: 'solution-developers' });
  const documents = [hub(), first, second];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.ok(errors.some((error) => error.includes('duplicate title')));
  assert.ok(errors.some((error) => error.includes('duplicate meta description')));
  assert.ok(errors.some((error) => error.includes('duplicate download source')));
});

test('rejects a landing page missing the WebPage schema', () => {
  const documents = [hub(), page({ webPage: false })];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.deepEqual(errors, ['/solutions/developers/: missing WebPage schema']);
});

test('rejects a landing page missing the BreadcrumbList schema', () => {
  const documents = [hub(), page({ breadcrumb: false })];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.deepEqual(errors, ['/solutions/developers/: missing BreadcrumbList schema']);
});

test('rejects a landing page missing its FAQ block', () => {
  // The checker fail-closed check for a page's FAQ is the rendered details block; a landing
  // page without it is the missing-FAQ failure mode the cluster validation reports.
  const documents = [hub(), page({ faq: false })];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.deepEqual(errors, ['/solutions/developers/: missing visible FAQ details']);
});

test('rejects a hub missing the CollectionPage schema', () => {
  const documents = [hub({ collectionPage: false }), page()];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.deepEqual(errors, ['/solutions/: missing CollectionPage schema']);
});

test('rejects a hub missing the ItemList schema', () => {
  const documents = [hub({ itemList: false }), page()];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.deepEqual(errors, ['/solutions/: missing ItemList schema']);
});

test('rejects a duplicate title across two routes', () => {
  const writers = page({ route: '/solutions/writers/', description: 'Dictate notes, essays, and email from your voice on Mac with free, private, on-device dictation built for everyday writers who need clean text every day.', source: 'solution-writers' });
  const documents = [hub(), page(), writers];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.deepEqual(errors, ['/solutions/writers/: duplicate title also used by /solutions/developers/']);
});

test('rejects a duplicate meta description across two routes', () => {
  const writers = page({ route: '/solutions/writers/', title: 'Free Dictation for Busy Writers on Mac | EnviousWispr', source: 'solution-writers' });
  const documents = [hub(), page(), writers];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.deepEqual(errors, ['/solutions/writers/: duplicate meta description also used by /solutions/developers/']);
});

test('rejects a duplicate download source across two routes', () => {
  const writers = page({ route: '/solutions/writers/', title: 'Free Dictation for Busy Writers on Mac | EnviousWispr', description: 'Dictate notes, essays, and email from your voice on Mac with free, private, on-device dictation built for everyday writers who need clean text every day.', source: 'solution-developers' });
  const documents = [hub(), page(), writers];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.deepEqual(errors, [
    '/solutions/writers/: duplicate download source also used by /solutions/developers/: solution-developers',
    '/solutions/writers/: duplicate download source also used by /solutions/developers/: solution-developers-bottom',
  ]);
});

test('rejects a direct answer longer than the window', () => {
  const documents = [hub(), page({ body: [words(30), words(70, 30), words(70, 100)] })];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.deepEqual(errors, ['/solutions/developers/: direct answer has 170 words, expected 134 to 167']);
});

test('rejects a solution route missing from the sitemap', () => {
  const documents = [hub(), page()];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap('/solutions/') });
  assert.deepEqual(errors, ['/solutions/developers/: expected once in sitemap, found 0']);
});

test('rejects a solution route listed twice in the sitemap', () => {
  const documents = [hub(), page()];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap('/solutions/', '/solutions/developers/', '/solutions/developers/') });
  assert.deepEqual(errors, ['/solutions/developers/: expected once in sitemap, found 2']);
});

test('rejects an em dash in rendered solution copy', () => {
  const documents = [hub(), page({ emDash: true })];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.deepEqual(errors, ['/solutions/developers/: rendered copy contains an em or en dash']);
});

test('rejects a landing page without exactly one H1', () => {
  const documents = [hub(), page({ h1Count: 2 })];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.deepEqual(errors, ['/solutions/developers/: expected exactly one H1, found 2']);
});

test('rejects a landing page with no H1 at all', () => {
  const documents = [hub(), page({ h1Count: 0 })];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.deepEqual(errors, ['/solutions/developers/: expected exactly one H1, found 0']);
});

test('rejects a landing page missing its title', () => {
  const documents = [hub(), page({ title: '' })];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.deepEqual(errors, ['/solutions/developers/: missing title']);
});

test('rejects a landing page missing its meta description', () => {
  const documents = [hub(), page({ description: '' })];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.deepEqual(errors, ['/solutions/developers/: missing meta description']);
});

test('rejects a landing page with a title outside the window', () => {
  const documents = [hub(), page({ title: 'Dictation for Mac' })];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.deepEqual(errors, ['/solutions/developers/: title has 17 characters, expected 50 to 60']);
});

test('rejects a landing page with a meta description outside the window', () => {
  const documents = [hub(), page({ description: 'Say it, ship it.' })];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.deepEqual(errors, ['/solutions/developers/: meta description has 16 characters, expected 145 to 155']);
});

test('rejects a landing page with a mismatched canonical', () => {
  const documents = [hub(), page({ canonical: 'https://enviouswispr.com/solutions/wrong/' })];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.deepEqual(errors, ['/solutions/developers/: canonical is https://enviouswispr.com/solutions/wrong/']);
});

test('rejects a landing page missing the link back to the solutions hub', () => {
  const documents = [hub(), page({ target: '/elsewhere/' })];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.deepEqual(errors, ['/solutions/developers/: missing link back to the solutions hub']);
});

test('rejects a landing page missing the direct download action', () => {
  const documents = [hub(), page({ downloadHref: 'https://example.com/get-enviouswispr' })];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.deepEqual(errors, ['/solutions/developers/: missing direct download action']);
});

test('rejects a landing page with a single download source', () => {
  const documents = [hub(), page({ bottomDownload: false })];
  const errors = validateSolutionCluster({ documents, sitemapXml: sitemap(...documents.map((item) => item.route)) });
  assert.deepEqual(errors, ['/solutions/developers/: expected distinct hero and bottom download sources']);
});

test('run exits 0 for a consistent build', () => {
  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'check-solutions-'));
  try {
    validSolutionsTree(tmpRoot);
    const { exitCode, logs, failures } = runQuiet(tmpRoot);
    assert.equal(exitCode, 0);
    assert.deepEqual(failures, []);
    assert.deepEqual(logs, ['solutions: 2 source route(s), 2 built route(s), 0 error(s)']);
  } finally {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
  }
});

test('run exits 1 when the source or dist directory is missing', () => {
  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'check-solutions-'));
  try {
    let result = runQuiet(tmpRoot);
    assert.equal(result.exitCode, 1);
    assert.deepEqual(result.failures, ['FAIL: solutions source or dist directory is missing. Run `npm run build` from website/.']);
    writeSource(tmpRoot, 'index.astro');
    result = runQuiet(tmpRoot);
    assert.equal(result.exitCode, 1);
    assert.deepEqual(result.failures, ['FAIL: solutions source or dist directory is missing. Run `npm run build` from website/.']);
  } finally {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
  }
});

test('run exits 1 when only the source directory is missing', () => {
  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'check-solutions-'));
  try {
    // dist exists but src/pages/solutions does not: the missing-sourceDir half of the OR guard.
    fs.mkdirSync(path.join(tmpRoot, 'dist'));
    const { exitCode, failures } = runQuiet(tmpRoot);
    assert.equal(exitCode, 1);
    assert.deepEqual(failures, ['FAIL: solutions source or dist directory is missing. Run `npm run build` from website/.']);
  } finally {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
  }
});

test('run exits 1 when a source route has no built index.html', () => {
  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'check-solutions-'));
  try {
    validSolutionsTree(tmpRoot);
    fs.rmSync(path.join(tmpRoot, 'dist', 'solutions', 'developers'), { recursive: true, force: true });
    const { exitCode, failures } = runQuiet(tmpRoot);
    assert.equal(exitCode, 1);
    assert.ok(failures.includes('FAIL: /solutions/developers/: source route missing from build'));
  } finally {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
  }
});

test('run exits 1 when a built route has no static source page', () => {
  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'check-solutions-'));
  try {
    validSolutionsTree(tmpRoot);
    fs.rmSync(path.join(tmpRoot, 'src', 'pages', 'solutions', 'developers.astro'), { recursive: true, force: true });
    const { exitCode, failures } = runQuiet(tmpRoot);
    assert.equal(exitCode, 1);
    assert.ok(failures.includes('FAIL: /solutions/developers/: built route has no static source page'));
  } finally {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
  }
});

test('run exits 1 when a route is missing from the sitemap', () => {
  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'check-solutions-'));
  try {
    validSolutionsTree(tmpRoot);
    fs.writeFileSync(path.join(tmpRoot, 'dist', 'sitemap-0.xml'), sitemap('/solutions/'));
    const { exitCode, failures } = runQuiet(tmpRoot);
    assert.equal(exitCode, 1);
    assert.deepEqual(failures, ['FAIL: /solutions/developers/: expected once in sitemap, found 0']);
  } finally {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
  }
});

test('run exits 1 when a route is listed twice in the sitemap', () => {
  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'check-solutions-'));
  try {
    validSolutionsTree(tmpRoot);
    fs.writeFileSync(path.join(tmpRoot, 'dist', 'sitemap-0.xml'), sitemap('/solutions/', '/solutions/developers/', '/solutions/developers/'));
    const { exitCode, failures } = runQuiet(tmpRoot);
    assert.equal(exitCode, 1);
    assert.deepEqual(failures, ['FAIL: /solutions/developers/: expected once in sitemap, found 2']);
  } finally {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
  }
});
