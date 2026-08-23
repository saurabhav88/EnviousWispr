#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const SITE = 'https://enviouswispr.com';

function textContent(html) {
  return html
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/\s+/g, ' ')
    .trim();
}

function wordCount(value) {
  const text = textContent(value);
  return text ? text.split(/\s+/).length : 0;
}

function matches(html, pattern) {
  return pattern.test(html);
}

export function validateSolutionDocument({ html, route, kind, knownRoutes }) {
  const errors = [];
  const h1Count = (html.match(/<h1\b/gi) ?? []).length;
  const title = html.match(/<title>([\s\S]*?)<\/title>/i)?.[1]?.trim() ?? '';
  const description = html.match(/<meta\s+name="description"\s+content="([^"]*)"/i)?.[1]?.trim() ?? '';
  const canonical = html.match(/<link\s+rel="canonical"\s+href="([^"]+)"/i)?.[1] ?? '';
  const sources = [...html.matchAll(/data-download-source="([^"]+)"/g)].map((match) => match[1]);

  if (h1Count !== 1) errors.push(`${route}: expected exactly one H1, found ${h1Count}`);
  if (!title) errors.push(`${route}: missing title`);
  if (!description) errors.push(`${route}: missing meta description`);
  if (title && (title.length < 50 || title.length > 60)) errors.push(`${route}: title has ${title.length} characters, expected 50 to 60`);
  if (description && (description.length < 145 || description.length > 155)) errors.push(`${route}: meta description has ${description.length} characters, expected 145 to 155`);
  if (canonical !== `${SITE}${route}`) errors.push(`${route}: canonical is ${canonical || '<missing>'}`);
  if (!matches(html, /"@type":"BreadcrumbList"/)) errors.push(`${route}: missing BreadcrumbList schema`);
  if (/[—–]/.test(textContent(html))) errors.push(`${route}: rendered copy contains an em or en dash`);

  if (kind === 'hub') {
    if (!matches(html, /"@type":"CollectionPage"/)) errors.push(`${route}: missing CollectionPage schema`);
    if (!matches(html, /"@type":"ItemList"/)) errors.push(`${route}: missing ItemList schema`);
  } else {
    if (!matches(html, /"@type":"WebPage"/)) errors.push(`${route}: missing WebPage schema`);
    if (!matches(html, /<details\b/)) errors.push(`${route}: missing visible FAQ details`);
    if (!matches(html, /href="\/solutions\/"/)) errors.push(`${route}: missing link back to the solutions hub`);
    if (!matches(html, /href="[^"]*EnviousWispr\.dmg"/)) errors.push(`${route}: missing direct download action`);
    if (sources.length < 2) errors.push(`${route}: expected distinct hero and bottom download sources`);

    const answerBlock = html.match(/<section\b[^>]*data-answer-block[^>]*>([\s\S]*?)<\/section>/i)?.[1] ?? '';
    const answerParagraphs = [...answerBlock.matchAll(/<p(?:\s[^>]*)?>([\s\S]*?)<\/p>/gi)];
    const answerParagraph = answerParagraphs.at(-1)?.[1] ?? '';
    const answerWords = wordCount(answerParagraph);
    if (answerWords < 134 || answerWords > 167) {
      errors.push(`${route}: direct answer has ${answerWords} words, expected 134 to 167`);
    }
  }

  for (const match of html.matchAll(/href="(\/solutions\/[a-z0-9-]*\/)"/g)) {
    if (!knownRoutes.has(match[1])) errors.push(`${route}: solution link points nowhere: ${match[1]}`);
  }

  return { errors, title, description, sources };
}

export function validateSolutionCluster({ documents, sitemapXml }) {
  const errors = [];
  const knownRoutes = new Set(documents.map((document) => document.route));
  const titles = new Map();
  const descriptions = new Map();
  const downloadSources = new Map();

  for (const document of documents) {
    const result = validateSolutionDocument({ ...document, knownRoutes });
    errors.push(...result.errors);
    for (const [value, map, label] of [
      [result.title, titles, 'title'],
      [result.description, descriptions, 'meta description'],
    ]) {
      if (!value) continue;
      if (map.has(value)) errors.push(`${document.route}: duplicate ${label} also used by ${map.get(value)}`);
      else map.set(value, document.route);
    }
    for (const source of result.sources) {
      if (downloadSources.has(source)) errors.push(`${document.route}: duplicate download source also used by ${downloadSources.get(source)}: ${source}`);
      else downloadSources.set(source, document.route);
    }
    const sitemapMatches = [...sitemapXml.matchAll(new RegExp(`<loc>${SITE}${document.route.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}</loc>`, 'g'))];
    if (sitemapMatches.length !== 1) errors.push(`${document.route}: expected once in sitemap, found ${sitemapMatches.length}`);
  }

  return errors;
}

function routeFromSource(filename) {
  return filename === 'index.astro' ? '/solutions/' : `/solutions/${filename.replace(/\.astro$/, '')}/`;
}

export function run(root = process.cwd()) {
  const sourceDir = path.join(root, 'src/pages/solutions');
  const distDir = path.join(root, 'dist');
  if (!fs.existsSync(sourceDir) || !fs.existsSync(distDir)) {
    console.error('FAIL: solutions source or dist directory is missing. Run `npm run build` from website/.');
    return 1;
  }

  const sourceRoutes = fs.readdirSync(sourceDir).filter((file) => file.endsWith('.astro')).map(routeFromSource).sort();
  const documents = sourceRoutes.map((route) => {
    const file = path.join(distDir, route.replace(/^\//, ''), 'index.html');
    if (!fs.existsSync(file)) return { route, kind: route === '/solutions/' ? 'hub' : 'landing', html: '' };
    return { route, kind: route === '/solutions/' ? 'hub' : 'landing', html: fs.readFileSync(file, 'utf8') };
  });
  const builtRoutes = fs.existsSync(path.join(distDir, 'solutions'))
    ? fs.readdirSync(path.join(distDir, 'solutions'), { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => `/solutions/${entry.name}/`)
      .concat('/solutions/')
      .sort()
    : [];

  const routeProblems = [
    ...sourceRoutes.filter((route) => !builtRoutes.includes(route)).map((route) => `${route}: source route missing from build`),
    ...builtRoutes.filter((route) => !sourceRoutes.includes(route)).map((route) => `${route}: built route has no static source page`),
  ];
  const sitemapXml = fs.readdirSync(distDir)
    .filter((file) => /^sitemap.*\.xml$/.test(file))
    .map((file) => fs.readFileSync(path.join(distDir, file), 'utf8'))
    .join('\n');
  const errors = [...routeProblems, ...validateSolutionCluster({ documents, sitemapXml })];

  console.log(`solutions: ${sourceRoutes.length} source route(s), ${builtRoutes.length} built route(s), ${errors.length} error(s)`);
  for (const error of errors) console.error(`FAIL: ${error}`);
  return errors.length ? 1 : 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(run());
}
