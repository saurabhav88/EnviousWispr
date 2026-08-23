import assert from 'node:assert/strict';
import test from 'node:test';
import { validateSolutionCluster } from './check-solutions.mjs';

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

function page({ route = '/solutions/developers/', title = 'Free Dictation for Developers on Mac | EnviousWispr', description = 'Dictate pull requests, reviews, documentation, and prompts on Mac with free, private, on-device voice input designed for technical vocabulary every day.', source = 'solution-developers', body = answerParagraphs, target = '/solutions/' } = {}) {
  return {
    route,
    kind: 'landing',
    html: `<!doctype html><html><head><title>${title}</title><meta name="description" content="${description}"><link rel="canonical" href="https://enviouswispr.com${route}"><script type="application/ld+json">{"@type":"WebPage"}</script><script type="application/ld+json">{"@type":"BreadcrumbList"}</script></head><body><h1>One heading</h1><a href="${target}">Solutions</a><a href="https://example.com/EnviousWispr.dmg" data-download-source="${source}">Download</a><section data-answer-block><p>Label</p><h2>Answer</h2>${prose(body)}</section><details><summary>Question</summary><p>Answer</p></details><a href="https://example.com/EnviousWispr.dmg" data-download-source="${source}-bottom">Download</a></body></html>`,
  };
}

function hub() {
  return {
    route: '/solutions/',
    kind: 'hub',
    html: '<!doctype html><html><head><title>Mac Dictation Solutions for Real Work | EnviousWispr</title><meta name="description" content="Find a free Mac dictation workflow for coding, writing, private offline work, and clean AI-polished text. Explore EnviousWispr and download free."><link rel="canonical" href="https://enviouswispr.com/solutions/"><script type="application/ld+json">{"@type":"CollectionPage","mainEntity":{"@type":"ItemList"}}</script><script type="application/ld+json">{"@type":"BreadcrumbList"}</script></head><body><h1>One heading</h1><a href="/solutions/developers/">Developers</a></body></html>',
  };
}

function sitemap(...routes) {
  return routes.map((route) => `<loc>https://enviouswispr.com${route}</loc>`).join('');
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
