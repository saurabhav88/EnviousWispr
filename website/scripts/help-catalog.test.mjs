// #3275: the help catalog the in-app help check matches feedback against.
// Run: `npm run test:catalog`.
import assert from "node:assert/strict";
import { test } from "node:test";

import { buildCatalog, extractSections, readerText, readHelpDir } from "./generate-help-article-catalog.mjs";
import { compareCatalogToPages } from "./check-help-catalog.mjs";

function article(slug, { deflection = "can_resolve", body = "Intro text.\n\n## Setting it up\n\nOpen **Settings**.\n", draft = false } = {}) {
  const lines = ["---", 'title: "Title"', 'description: "Description"', "updated: 2026-09-28"];
  if (deflection !== null) lines.push(`deflection: "${deflection}"`);
  if (draft) lines.push("draft: true");
  return { file: `${slug}.md`, source: `${lines.join("\n")}\n---\n${body}` };
}

test("an article without a deflection policy fails the build of the catalog", () => {
  assert.throws(() => buildCatalog([article("a", { deflection: null })]), /a\.md: missing deflection/);
});

test("an unknown deflection policy fails", () => {
  assert.throws(() => buildCatalog([article("a", { deflection: "maybe" })]), /deflection "maybe" is not one of/);
});

test("the catalog version changes when body text or policy changes, and not otherwise", () => {
  const base = buildCatalog([article("a"), article("b")]).catalogVersion;
  assert.equal(buildCatalog([article("b"), article("a")]).catalogVersion, base);
  assert.notEqual(buildCatalog([article("a", { body: "Intro text.\n\n## Setting it up\n\nOpen **Help**.\n" }), article("b")]).catalogVersion, base);
  assert.notEqual(buildCatalog([article("a", { deflection: "show_but_always_send" }), article("b")]).catalogVersion, base);
});

test("draft articles are left out", () => {
  const catalog = buildCatalog([article("a"), article("b", { draft: true })]);
  assert.deepEqual(catalog.articles.map((a) => a.slug), ["a"]);
});

test("sections are the intro plus level-2 and level-3 headings, with deeper headings folded in", () => {
  const sections = extractSections("page", "Intro.\n\n## First\n\nOne.\n\n### Second part\n\nTwo.\n\n#### Detail\n\nThree.\n");
  assert.deepEqual(
    sections.map((s) => [s.id, s.heading, s.text, s.url]),
    [
      ["page#intro", null, "Intro.", "https://enviouswispr.com/help/page/"],
      ["page#first", "First", "One.", "https://enviouswispr.com/help/page/#first"],
      ["page#second-part", "Second part", "Two.\n\nDetail\n\nThree.", "https://enviouswispr.com/help/page/#second-part"],
    ],
  );
});

test("an article with no intro text starts at its first heading", () => {
  assert.deepEqual(extractSections("page", "## Only\n\nText.\n").map((s) => s.id), ["page#only"]);
});

test("repeated headings get distinct ids, the same way every run", () => {
  const body = "## Steps\n\nA.\n\n## Steps\n\nB.\n";
  const first = extractSections("page", body).map((s) => s.id);
  assert.deepEqual(first, ["page#steps", "page#steps-1"]);
  assert.deepEqual(extractSections("page", body).map((s) => s.id), first);
});

test("a heading with no text under it fails", () => {
  assert.throws(() => extractSections("page", "## Empty\n\n## Next\n\nText.\n"), /section "Empty" has no text/);
});

test("reader text drops Markdown marks but keeps the words", () => {
  assert.equal(
    readerText("Open **Settings** \\> [Keybinds](/help/x/), press `Esc`, read _History_.\n> quoted *note*"),
    "Open Settings > Keybinds, press Esc, read History.\nquoted note",
  );
});

const page = (body) => `<h1>Title</h1><div class="help-body">${body}</div><footer class="help-foot"><h2>Related</h2></footer>`;

test("the page check finds a missing anchor, missing text and a missing page, and passes a matching page", () => {
  const catalog = buildCatalog([article("a")]);
  const good = page('<p>Intro text.</p><h2 id="setting-it-up">Setting it up</h2><p>Open <strong>Settings</strong>.</p>');
  const ok = compareCatalogToPages(catalog, () => good);
  assert.deepEqual(ok.failures, []);
  assert.equal(ok.anchors, 1);
  assert.equal(ok.lines, 2);
  const noAnchor = compareCatalogToPages(catalog, () => good.replace(' id="setting-it-up"', ""));
  assert.deepEqual(noAnchor.failures, [
    'a: built section "(no id: Setting it up)" is missing from the catalog',
    'a#setting-it-up: no heading with id="setting-it-up"',
  ]);
  const noText = compareCatalogToPages(catalog, () => good.replace("Intro text.", "Other."));
  assert.deepEqual(noText.failures, ['a#intro: text not in this section of the page: "Intro text."']);
  const extraHeading = compareCatalogToPages(catalog, () => good.replace("</div>", '<h3 id="extra">Extra</h3><p>More.</p></div>'));
  assert.deepEqual(extraHeading.failures, ['a: built section "extra" is missing from the catalog']);
  assert.deepEqual(compareCatalogToPages(catalog, () => null).failures, ["a: no built page at dist/help/a/index.html"]);
});

test("the page check fails text generated under the wrong section", () => {
  const catalog = buildCatalog([article("a", { body: "## One\n\nFirst words.\n\n## Two\n\nSecond words.\n" })]);
  const swapped = page('<h2 id="one">One</h2><p>Second words.</p><h2 id="two">Two</h2><p>First words.</p>');
  assert.deepEqual(compareCatalogToPages(catalog, () => swapped).failures, [
    'a#one: text not in this section of the page: "First words."',
    'a#two: text not in this section of the page: "Second words."',
  ]);
});

test("a table becomes one labeled line per row, and the page check accepts its built table", () => {
  const body = "## Engines\n\n| Feature | Parakeet |\n| --- | --- |\n| Speed | **Faster** |\n| Setup | Downloaded for you |\n";
  const catalog = buildCatalog([article("a", { body })]);
  assert.equal(catalog.articles[0].sections[0].text, "Feature: Speed; Parakeet: Faster\nFeature: Setup; Parakeet: Downloaded for you");
  const built = page('<h2 id="engines">Engines</h2><table><thead><tr><th>Feature</th><th>Parakeet</th></tr></thead><tbody><tr><td>Speed</td><td><strong>Faster</strong></td></tr><tr><td>Setup</td><td>Downloaded for you</td></tr></tbody></table>');
  assert.deepEqual(compareCatalogToPages(catalog, () => built).failures, []);
  // The same values in the wrong rows: every cell is still on the page, so only a
  // whole-row comparison catches it.
  const swapped = built.replace("<strong>Faster</strong>", "Downloaded for you").replace("<td>Downloaded for you</td></tr></tbody>", "<td>Faster</td></tr></tbody>");
  assert.deepEqual(compareCatalogToPages(catalog, () => swapped).failures, [
    'a#engines: table row not in this section of the page: "Feature: Speed; Parakeet: Faster"',
    'a#engines: table row not in this section of the page: "Feature: Setup; Parakeet: Downloaded for you"',
  ]);
});

test("every real help article is in the catalog with a policy", () => {
  const entries = readHelpDir();
  const published = entries.filter((e) => !/^draft:\s*true\s*$/m.test(e.source.split(/\n---\n/)[0]));
  const catalog = buildCatalog(entries);
  assert.ok(published.length > 0);
  assert.equal(catalog.articles.length, published.length);
  assert.ok(catalog.articles.every((a) => a.sections.length > 0 && a.deflection));
});
