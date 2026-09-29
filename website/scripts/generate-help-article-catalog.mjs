#!/usr/bin/env node
// Writes the help catalog the in-app help check matches feedback against (#3275).
// The Pages Function at /api/app/help-check cannot read Markdown at runtime, so it
// bundles this SNAPSHOT: every published help article's slug, title, description,
// deflection policy and its sections (heading, reader-visible text, deep link),
// plus a content hash (`catalogVersion`) stamped on every help-check answer.
//
// Run after changing any help article, then commit the result:
//   node website/scripts/generate-help-article-catalog.mjs
// `--check` regenerates in memory and fails if the committed file is stale; the
// website prebuild runs it, so a stale catalog cannot deploy.
//
// Dependency-free on purpose except github-slugger, the same slugger Astro uses
// for heading ids; scripts/check-help-catalog.mjs proves every generated anchor
// exists in the built pages.

import { createHash } from "node:crypto";
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import GithubSlugger from "github-slugger";
import { DEFLECTION_POLICIES } from "../src/data/help-deflection.js";

const websiteRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const HELP_DIR = join(websiteRoot, "src/content/help");
export const OUT_FILE = join(websiteRoot, "functions/_lib/help-catalog.js");
const SITE = "https://enviouswispr.com";

function splitFrontmatter(source, file) {
  const m = source.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!m) throw new Error(`${file}: no frontmatter block`);
  return { frontmatter: m[1], body: m[2] };
}

// Reads one `field: "value"` line; every help article writes these as one
// double-quoted string, and anything else fails loudly rather than guessing.
function frontmatterString(frontmatter, field, file) {
  const line = frontmatter.split("\n").find((l) => l.startsWith(`${field}:`));
  if (!line) throw new Error(`${file}: missing ${field}`);
  const raw = line.slice(field.length + 1).trim();
  let value;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new Error(`${file}: ${field} is not one double-quoted string: ${raw}`);
  }
  if (typeof value !== "string" || !value.trim()) throw new Error(`${file}: ${field} is empty`);
  return value;
}

// A Markdown table becomes one line per body row that names each column, so a
// row still says what its values mean without the header next to it:
// "| Feature | Parakeet |" over "| Speed | Faster |" gives "Feature: Speed; Parakeet: Faster".
function tablesToText(markdown) {
  const out = [];
  const lines = markdown.split("\n");
  const cells = (line) => line.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((c) => c.trim());
  const isSeparator = (line) => /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$/.test(line);
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].trim().startsWith("|") && i + 1 < lines.length && isSeparator(lines[i + 1])) {
      const header = cells(lines[i]);
      i += 2;
      for (; i < lines.length && lines[i].trim().startsWith("|"); i++) {
        out.push(cells(lines[i]).map((c, k) => (header[k] ? `${header[k]}: ${c}` : c)).join("; "));
      }
      i--;
    } else {
      out.push(lines[i]);
    }
  }
  return out.join("\n");
}

// Markdown to the text a reader sees: link targets, emphasis and code marks go.
export function readerText(markdown) {
  return tablesToText(markdown)
    .split("\n")
    .map((line) => line.replace(/^#{4,6}\s+/, "").replace(/^\s*>\s?/, ""))
    .join("\n")
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/(^|[^*])\*([^*\n]+)\*/g, "$1$2")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/(^|[^\w\\])_([^_\n]+)_(?!\w)/g, "$1$2")
    .replace(/\\([\\`*_{}\[\]()#+\-.!>|<])/g, "$1")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

// Sections are the article intro plus every level-2 and level-3 heading; deeper
// headings stay inside their parent section. Anchors follow Astro's heading ids.
export function extractSections(slug, body) {
  const slugger = new GithubSlugger();
  let current = { anchor: null, heading: null, lines: [] };
  const raw = [current];
  for (const line of body.split("\n")) {
    const h = line.match(/^(#{2,3})\s+(.+?)\s*#*\s*$/);
    if (h) {
      const heading = readerText(h[2]);
      current = { anchor: slugger.slug(heading), heading, lines: [] };
      raw.push(current);
    } else {
      current.lines.push(line);
    }
  }
  const sections = [];
  for (const s of raw) {
    const text = readerText(s.lines.join("\n"));
    if (s.anchor === null && !text) continue;
    if (!text && s.anchor !== null) throw new Error(`${slug}: section "${s.heading}" has no text`);
    sections.push({
      id: `${slug}#${s.anchor ?? "intro"}`,
      anchor: s.anchor,
      heading: s.heading,
      text,
      url: `${SITE}/help/${slug}/${s.anchor ? `#${s.anchor}` : ""}`,
    });
  }
  const ids = sections.map((s) => s.id);
  const dup = ids.find((id, i) => ids.indexOf(id) !== i);
  if (dup) throw new Error(`${slug}: duplicate section id ${dup}`);
  return sections;
}

export function parseArticle(file, source) {
  const { frontmatter, body } = splitFrontmatter(source, file);
  if (/^draft:\s*true\s*$/m.test(frontmatter)) return null;
  const slug = file.replace(/\.md$/, "");
  const deflection = frontmatterString(frontmatter, "deflection", file);
  if (!DEFLECTION_POLICIES.includes(deflection)) {
    throw new Error(`${file}: deflection "${deflection}" is not one of ${DEFLECTION_POLICIES.join(", ")}`);
  }
  const sections = extractSections(slug, body);
  if (sections.length === 0) throw new Error(`${file}: no sections`);
  return {
    slug,
    title: frontmatterString(frontmatter, "title", file),
    description: frontmatterString(frontmatter, "description", file),
    deflection,
    url: `${SITE}/help/${slug}/`,
    sections,
  };
}

export function buildCatalog(entries) {
  if (entries.length === 0) throw new Error("no help articles found");
  const articles = entries
    .slice()
    .sort((a, b) => a.file.localeCompare(b.file))
    .map(({ file, source }) => parseArticle(file, source))
    .filter(Boolean);
  const catalogVersion = createHash("sha256").update(JSON.stringify(articles)).digest("hex").slice(0, 12);
  return { catalogVersion, articles };
}

export function renderCatalog(catalog) {
  return (
    "// GENERATED by website/scripts/generate-help-article-catalog.mjs. Do not edit by hand.\n" +
    "// Regenerate after any help-article change and commit it (#3275).\n" +
    `export default ${JSON.stringify(catalog, null, 2)};\n`
  );
}

export function readHelpDir(dir = HELP_DIR) {
  return readdirSync(dir)
    .filter((f) => f.endsWith(".md"))
    .map((file) => ({ file, source: readFileSync(join(dir, file), "utf8") }));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const entries = readHelpDir();
  const catalog = buildCatalog(entries);
  const output = renderCatalog(catalog);
  const sections = catalog.articles.reduce((n, a) => n + a.sections.length, 0);
  if (process.argv.includes("--check")) {
    let committed = "";
    try {
      committed = readFileSync(OUT_FILE, "utf8");
    } catch {}
    if (committed !== output) {
      console.error(`help catalog is stale: run node website/scripts/generate-help-article-catalog.mjs and commit ${OUT_FILE}`);
      process.exit(1);
    }
    console.log(`help catalog current: ${catalog.articles.length} articles, ${sections} sections, catalogVersion ${catalog.catalogVersion}`);
  } else {
    writeFileSync(OUT_FILE, output);
    console.log(`wrote ${catalog.articles.length} articles, ${sections} sections, catalogVersion ${catalog.catalogVersion}, to ${OUT_FILE}`);
  }
}
