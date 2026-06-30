// Unit tests for the pure query-builder / extractor / formatter helpers (no network).
// Run: node --test  (from workers/weekly-digest/)
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  downloadIntentsHogQL,
  downloadSourcesHogQL,
  botExcludedHogQL,
  extractTrendTotal,
  extractHogScalar,
  extractHogRows,
  sourceLabel,
  formatSourceBreakdown,
  buildEmbed,
} from "../src/index.js";

// ---- HogQL builders: must qualify every event-property as properties.<name> ----
// A bare excluded_reason / source_bucket (not preceded by "properties.") would fail
// in PostHog HogQL. This regex catches the regression Codex flagged twice.
const BARE_PROP = /(?<!properties\.)\b(excluded_reason|source_bucket)\b/;

test("downloadIntentsHogQL: union of both events, bot-excluded, fully qualified", () => {
  const q = downloadIntentsHogQL("2026-06-23", "2026-06-30");
  assert.match(q, /event = 'download_clicked'/);
  assert.match(q, /event = 'download_redirect'/);
  assert.match(q, /coalesce\(properties\.excluded_reason, ''\) = ''/);
  assert.ok(!BARE_PROP.test(q), "no bare event-property refs allowed");
  assert.match(q, /2026-06-23/);
  assert.match(q, /2026-06-30/);
});

test("downloadSourcesHogQL: groups off-site only by qualified source_bucket", () => {
  const q = downloadSourcesHogQL("2026-06-23", "2026-06-30");
  assert.match(q, /properties\.source_bucket/);
  assert.match(q, /event = 'download_redirect'/);
  assert.ok(!/download_clicked/.test(q), "source breakdown must be off-site only");
  assert.match(q, /coalesce\(properties\.excluded_reason, ''\) = ''/);
  assert.match(q, /GROUP BY bucket/);
  assert.ok(!BARE_PROP.test(q), "no bare event-property refs allowed");
});

test("botExcludedHogQL: counts non-empty excluded_reason, qualified", () => {
  const q = botExcludedHogQL("2026-06-23", "2026-06-30");
  assert.match(q, /coalesce\(properties\.excluded_reason, ''\) != ''/);
  assert.match(q, /event = 'download_redirect'/);
  assert.ok(!BARE_PROP.test(q), "no bare event-property refs allowed");
});

// ---- extractors ----
test("extractHogScalar: first cell, '?' fallbacks", () => {
  assert.equal(extractHogScalar({ results: [[5]] }), 5);
  assert.equal(extractHogScalar({ results: [[0]] }), 0); // zero is a real count, not "?"
  assert.equal(extractHogScalar({ results: [] }), "?");
  assert.equal(extractHogScalar(null), "?");
  assert.equal(extractHogScalar({}), "?");
});

test("extractHogRows: passthrough; null on failure (unknown != empty)", () => {
  assert.deepEqual(extractHogRows({ results: [["reddit", 2], ["blog", 1]] }), [["reddit", 2], ["blog", 1]]);
  assert.deepEqual(extractHogRows({ results: [] }), []); // genuine zero week is a real []
  assert.equal(extractHogRows(null), null); // failed query -> unknown, NOT empty
  assert.equal(extractHogRows({ results: "nope" }), null);
});

test("extractTrendTotal: aggregated_value, summed data, fallback", () => {
  assert.equal(extractTrendTotal({ results: [{ aggregated_value: 12 }] }, 0), 12);
  assert.equal(extractTrendTotal({ results: [{ data: [1, 2, 3] }] }, 0), 6);
  assert.equal(extractTrendTotal({ results: [] }, 0), "?");
  assert.equal(extractTrendTotal(null, 0), "?");
});

// ---- labels / formatting ----
test("sourceLabel: known maps, unknown/null -> Other", () => {
  assert.equal(sourceLabel("github_readme"), "GitHub README");
  assert.equal(sourceLabel("reddit"), "Reddit");
  assert.equal(sourceLabel("ai_assistant"), "AI assistant");
  assert.equal(sourceLabel("some_new_bucket"), "Other");
  assert.equal(sourceLabel(null), "Other");
  assert.equal(sourceLabel(undefined), "Other");
});

test("formatSourceBreakdown: empty vs unknown vs rows", () => {
  assert.equal(formatSourceBreakdown([]), "No off-site downloads yet"); // genuine zero
  assert.equal(formatSourceBreakdown(null), "Sources unavailable"); // query failed/unknown
  const out = formatSourceBreakdown([["github_readme", 3], ["reddit", 1], ["mystery", 1]]);
  assert.match(out, /GitHub README: 3/);
  assert.match(out, /Reddit: 1/);
  assert.match(out, /Other: 1/); // unknown bucket never disappears
});

// ---- embed smoke ----
const cf = { totalUniques: 10, totalPageViews: 50, totalRequests: 100, topCountries: [["United States", 5]] };
const gh = { totalDownloads: 1234, latestVersion: "v1.10.2" };

test("buildEmbed: shows Download Intents + Download Sources, drops legacy labels", () => {
  const ph = {
    websiteVisitors: 9, websitePageViews: 40,
    downloadIntents: 7, downloadSources: [["github_readme", 4], ["reddit", 2]],
    botExcluded: 3, weeklyActiveUsers: 20, newUsers: 2,
  };
  const json = JSON.stringify(buildEmbed("2026-06-23", "2026-06-30", cf, gh, ph));
  assert.match(json, /Download Intents \(7d\)/);
  assert.match(json, /Download Sources \(7d\)/);
  assert.match(json, /Off-site bots excluded: 3/);
  assert.match(json, /GitHub README: 4/);
  assert.ok(!/Download Clicks/.test(json), "legacy 'Download Clicks' label removed");
  assert.ok(!/Top Referrers/.test(json), "broken 'Top Referrers' section removed");
  // All-time GitHub file-download count stays separate and labeled.
  assert.match(json, /All-Time DMG Downloads/);
});

test("buildEmbed: empty sources renders the friendly placeholder", () => {
  const ph = {
    websiteVisitors: 9, websitePageViews: 40,
    downloadIntents: 0, downloadSources: [], botExcluded: 0,
    weeklyActiveUsers: 20, newUsers: 2,
  };
  const json = JSON.stringify(buildEmbed("2026-06-23", "2026-06-30", cf, gh, ph));
  assert.match(json, /No off-site downloads yet/);
});

test("buildEmbed: failed sources query renders 'Sources unavailable', not a false zero", () => {
  const ph = {
    websiteVisitors: 9, websitePageViews: 40,
    downloadIntents: "?", downloadSources: null, botExcluded: "?",
    weeklyActiveUsers: 20, newUsers: 2,
  };
  const json = JSON.stringify(buildEmbed("2026-06-23", "2026-06-30", cf, gh, ph));
  assert.match(json, /Sources unavailable/);
  assert.ok(!/No off-site downloads yet/.test(json), "a failed query must not look like a true zero");
});
