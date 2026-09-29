#!/usr/bin/env node
// Proves the help catalog (#3275) matches the BUILT help pages: every generated
// section anchor exists as an element id on its page, and every line of every
// section's text appears in that page's visible text. Run after `npm run build`
// (part of `npm run check:help`); it reads dist/, so it cannot pass on a stale build
// of different content.

import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const dist = resolve(dirname(fileURLToPath(import.meta.url)), "../dist");

function visibleText(html) {
  return html
    .replace(/<script[\s\S]*?<\/script>/g, " ")
    .replace(/<style[\s\S]*?<\/style>/g, " ")
    .replace(/<\/?(?:p|li|ul|ol|h[1-6]|div|section|article|td|th|tr|table|thead|tbody|br|hr|blockquote|pre|nav|header|footer|main)\b[^>]*>/gi, " ")
    .replace(/<[^>]+>/g, "")
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&nbsp;/g, " ");
}

// Typography the renderer may apply (curly quotes, ellipsis) and whitespace.
function norm(s) {
  return s
    .replace(/[‘’]/g, "'")
    .replace(/[“”]/g, '"')
    .replace(/…/g, "...")
    .replace(/\s+/g, " ")
    .trim();
}

// Splits the built article body (between the help-body container and the page
// footer) at each level-2/3 heading, keyed by the heading's id; "" holds the intro.
// A section's text is checked only against its own part of the page, so text
// generated under the wrong link fails.
export function builtSections(html) {
  const marker = html.indexOf('class="help-body"');
  if (marker === -1) return null;
  const start = html.indexOf(">", marker) + 1;
  const end = html.indexOf('<footer class="help-foot"', start);
  const body = html.slice(start, end === -1 ? undefined : end);
  const parts = new Map();
  const heading = /<h([23])\b([^>]*)>([\s\S]*?)<\/h\1>/g;
  let key = "";
  let from = 0;
  for (const m of body.matchAll(heading)) {
    parts.set(key, (parts.get(key) ?? "") + body.slice(from, m.index));
    const id = m[2].match(/\sid="([^"]+)"/);
    key = id ? id[1] : `(no id: ${norm(visibleText(m[3]))})`;
    from = m.index + m[0].length;
  }
  parts.set(key, (parts.get(key) ?? "") + body.slice(from));
  return new Map([...parts].map(([k, v]) => [k, norm(visibleText(v))]));
}

// Pieces of one generated line that must appear verbatim on the page. Table rows
// are generated as "Column: value; Column: value", so labels and values are
// checked separately; plain sentences split the same way stay verbatim pieces.
function pieces(line) {
  return line.split(/;\s+|:\s+/).map((p) => p.trim()).filter(Boolean);
}

export function compareCatalogToPages(catalog, readPage) {
  let anchors = 0;
  let lines = 0;
  const failures = [];
  for (const article of catalog.articles) {
    const html = readPage(article.slug);
    if (html === null) {
      failures.push(`${article.slug}: no built page at dist/help/${article.slug}/index.html`);
      continue;
    }
    const parts = builtSections(html);
    if (parts === null) {
      failures.push(`${article.slug}: built page has no help-body container`);
      continue;
    }
    const generated = new Set(article.sections.map((sec) => sec.anchor ?? ""));
    for (const [key, text] of parts) {
      if (!generated.has(key) && text) failures.push(`${article.slug}: built section "${key || "intro"}" is missing from the catalog`);
    }
    for (const section of article.sections) {
      const key = section.anchor ?? "";
      if (section.anchor !== null) anchors++;
      const text = parts.get(key);
      if (text === undefined) {
        failures.push(`${section.id}: no heading with id="${section.anchor}"`);
        continue;
      }
      for (const raw of section.text.split("\n")) {
        const line = norm(raw.replace(/^\s*(?:[-*+]|\d+\.)\s+/, ""));
        if (!line) continue;
        lines++;
        const missing = pieces(line).find((p) => !text.includes(p));
        if (missing !== undefined) failures.push(`${section.id}: text not in this section of the page: "${missing.slice(0, 80)}"`);
      }
    }
  }
  return { anchors, lines, failures };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const { default: catalog } = await import("../functions/_lib/help-catalog.js");
  const { anchors, lines, failures } = compareCatalogToPages(catalog, (slug) => {
    try {
      return readFileSync(join(dist, "help", slug, "index.html"), "utf8");
    } catch {
      return null;
    }
  });
  if (anchors === 0 || lines === 0) {
    console.error(`FAIL: checked ${anchors} anchors and ${lines} text lines; expected both above zero.`);
    process.exit(1);
  }
  if (failures.length) {
    console.error(`FAIL: ${failures.length} help catalog mismatches with the built pages:`);
    for (const f of failures.slice(0, 40)) console.error(`  ${f}`);
    process.exit(1);
  }
  console.log(`OK: help catalog matches the built pages (${catalog.articles.length} articles, ${anchors} anchors, ${lines} text lines).`);
}
