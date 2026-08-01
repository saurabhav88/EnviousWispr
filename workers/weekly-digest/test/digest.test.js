/**
 * Weekly digest tests (#1243, #1589).
 *
 * The #1589 suites drive the REAL `runDigest` with fetch intercepted, rather
 * than re-assembling the digest from its parts. A harness that re-implements
 * the orchestration is a second authority: it passes happily while production
 * takes another path.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import worker, {
  isAuthorizedTrigger,
  runDigest,
  resolveWeekWindow,
  fetchCloudflareStats,
  fetchGitHubDownloads,
  appUsageSql,
  websiteSql,
  downloadsSql,
  downloadSourcesSql,
  sourceLabel,
  formatSourceBreakdown,
  formatCloudflare,
  formatWebsite,
  formatDownloads,
  formatAppUsage,
  SOURCE_LABELS,
} from "../src/index.js";

// Every event-property reference must be qualified as properties.<name>: a bare
// name does not resolve in PostHog HogQL. This regex catches the regression
// Codex flagged twice on the pre-#1589 builders.
const BARE_PROP = /(?<!properties\.)\b(excluded_reason|source_bucket|app_version)\b/;

const ENV = {
  POSTHOG_PROJECT_ID: "354235",
  POSTHOG_PERSONAL_API_KEY: "k",
  CF_ZONE_ID: "zone",
  CF_EMAIL: "e",
  CF_API_KEY: "cfk",
  GITHUB_REPO: "saurabhav88/EnviousWispr",
  DISCORD_WEBHOOK_URL: "https://discord.test/hook",
  TRIGGER_SECRET: "s3cret",
};

// Pinned so the window is deterministic: Monday 2026-08-03 13:00 UTC ->
// window 2026-07-27 .. 2026-08-03 exclusive, last included day 2026-08-02.
const NOW = new Date("2026-08-03T13:00:00Z");

const ok = (body) => ({ ok: true, status: 200, json: async () => body });
const fail = (status) => ({ ok: false, status, json: async () => ({}), body: { cancel: async () => {} } });

const POSTHOG_ROWS = {
  dev_ids: { results: [["dev-a"], ["dev-b"]], columns: ["distinct_id"] },
  website: { results: [[226, 119]], columns: ["views", "visitors"] },
  downloads: { results: [[36, 11]], columns: ["intents", "bots_excluded"] },
  download_sources: { results: [["github_readme", 20], ["reddit", 8]], columns: ["bucket", "n"] },
  app_usage: { results: [[189, 51]], columns: ["active", "fresh"] },
  onboard_activate: { results: [[31, 24]], columns: ["onboarded", "activated"] },
};

const CF_BODY = {
  data: { viewer: { zones: [{
    totals: [{ sum: { requests: 5000, pageViews: 900 }, uniq: { uniques: 300 } }],
    byDay: [{ dimensions: { date: "2026-07-27" }, sum: { pageViews: 100, countryMap: [
      { clientCountryName: "United States", requests: 3000 },
      { clientCountryName: "India", requests: 900 },
    ] } }],
  }] } },
};

const RELEASES_PAGE = (count, startTag = 1) =>
  Array.from({ length: count }, (_, i) => ({
    tag_name: `v1.${startTag + i}.0`,
    assets: [{ name: "EnviousWispr.dmg", download_count: 10 }],
  }));

/**
 * One harness driving the real runDigest. `overrides` replaces individual
 * PostHog query responses (keyed by the UNPREFIXED query name) or the
 * Cloudflare / GitHub behaviour.
 */
function harness(overrides = {}) {
  const state = { posts: [], queryNames: [], inFlight: 0, peakInFlight: 0, posthogCalls: 0, githubPages: [], sql: [] };

  const fetchFn = async (url, init) => {
    if (String(url).includes("posthog.com")) {
      state.posthogCalls += 1;
      state.inFlight += 1;
      state.peakInFlight = Math.max(state.peakInFlight, state.inFlight);
      try {
        const body = JSON.parse(init.body);
        const name = body.name;
        state.queryNames.push(name);
        state.sql.push(body.query.query);
        assert.ok(name.startsWith("weekly_digest_"), `query name must carry the worker label, got ${name}`);
        const key = name.replace(/^weekly_digest_/, "");
        // Yield, so concurrent work actually overlaps and peakInFlight means
        // something rather than recording a sequence of instant resolutions.
        await new Promise((r) => setImmediate(r));
        const override = overrides.posthog?.[key];
        if (typeof override === "function") return override();
        return ok(POSTHOG_ROWS[key] ?? { results: [], columns: [] });
      } finally {
        state.inFlight -= 1;
      }
    }
    if (String(url).includes("api.cloudflare.com")) {
      return overrides.cloudflare ? overrides.cloudflare() : ok(CF_BODY);
    }
    if (String(url).includes("api.github.com")) {
      const page = Number(new URL(url).searchParams.get("page"));
      state.githubPages.push(page);
      if (overrides.github) return overrides.github(page);
      return ok(page === 1 ? RELEASES_PAGE(100) : RELEASES_PAGE(45, 101));
    }
    if (String(url).includes("discord.test")) {
      state.posts.push(JSON.parse(init.body));
      return { status: 204 };
    }
    throw new Error(`unexpected fetch to ${url}`);
  };

  const run = (env = ENV) =>
    runDigest(env, { fetchFn, now: NOW, hogqlOpts: { fetchFn, sleepFn: async () => {}, randomFn: () => 0 } });

  return { state, fetchFn, run };
}

// ---- Window ------------------------------------------------------------------

test("the window is seven whole UTC days, half-open, with no shared day", () => {
  const w = resolveWeekWindow(NOW);
  assert.equal(w.startDay, "2026-07-27");
  assert.equal(w.lastDay, "2026-08-02");
  assert.equal(w.end.toISOString(), "2026-08-03T00:00:00.000Z");
  // Seven days, not the eight the shipped worker measured.
  assert.equal((w.end - w.start) / 86400000, 7);
  // Exclusive end: consecutive weeks must not share a day.
  const next = resolveWeekWindow(new Date("2026-08-10T13:00:00Z"));
  assert.equal(next.startDay, "2026-08-03");
  assert.equal(w.lastDay < next.startDay, true);
});

test("the SQL window clause is half-open, never an inclusive toDate range", () => {
  const w = resolveWeekWindow(NOW);
  assert.match(w.win, /timestamp >= '2026-07-27 00:00:00' AND timestamp < '2026-08-03 00:00:00'/);
  // An inclusive `<=` is what reintroduces the eighth day and the double count.
  assert.doesNotMatch(w.win, /<=/);
});

// ---- Query shape -------------------------------------------------------------

test("every event property is qualified as properties.<name>", () => {
  const win = "timestamp >= 'x' AND timestamp < 'y'";
  for (const sql of [appUsageSql("P", win), websiteSql(win), downloadsSql(win), downloadSourcesSql(win)]) {
    assert.doesNotMatch(sql, BARE_PROP);
  }
});

test("app usage carries the production predicate; website and downloads do NOT", () => {
  const prod = "properties.environment = 'production'\n    AND distinct_id NOT IN ('dev-a')";
  const win = "timestamp >= 'x' AND timestamp < 'y'";
  assert.match(appUsageSql(prod, win), /environment = 'production'/);
  assert.match(appUsageSql(prod, win), /distinct_id NOT IN/);
  // Website events carry no environment property at all, so the production
  // predicate would return ZERO rather than the same rows more slowly.
  for (const sql of [websiteSql(win), downloadsSql(win), downloadSourcesSql(win)]) {
    assert.doesNotMatch(sql, /environment = 'production'/);
    assert.doesNotMatch(sql, /distinct_id NOT IN/);
  }
});

test("only the pageview query is host-scoped; download queries must NOT be", () => {
  const win = "timestamp >= 'x' AND timestamp < 'y'";
  assert.match(websiteSql(win), /properties\.\$host IN \('enviouswispr\.com', 'www\.enviouswispr\.com'\)/);
  // download_redirect is emitted server-side with no $host, so a host filter
  // here would silently drop every off-site redirect.
  assert.doesNotMatch(downloadsSql(win), /\$host/);
  assert.doesNotMatch(downloadSourcesSql(win), /\$host/);
});

test("no query interpolates the production predicate more than once", () => {
  const prod = "properties.environment = 'production'";
  const win = "timestamp >= 'x' AND timestamp < 'y'";
  // Repeating an unbounded dev-exclusion predicate inside one query is the
  // shape that timed out production PostHog in #1655 and #1716.
  assert.equal(appUsageSql(prod, win).split(prod).length - 1, 1);
});

test("the merged downloads query preserves both original predicates", () => {
  const sql = downloadsSql("W");
  assert.match(sql, /event = 'download_clicked'/);
  assert.match(sql, /event = 'download_redirect' AND coalesce\(properties\.excluded_reason, ''\) = ''/);
  assert.match(sql, /coalesce\(properties\.excluded_reason, ''\) != ''/);
  // Scoped to the two relevant event types, or the merge scans everything.
  assert.match(sql, /WHERE event IN \('download_clicked', 'download_redirect'\)/);
});

test("app usage counts fresh installs by the app's own flag, not PostHog first-seen", () => {
  const sql = appUsageSql("P", "W");
  assert.match(sql, /uniqExactIf\(distinct_id, event = 'onboarding\.started'\) AS fresh/);
  // The STATE flag re-counted anyone who never finished setup, every window.
  assert.doesNotMatch(sql, /is_fresh_install/);
  // Single whole-window uniqExactIf counts, never per-bucket counts a caller
  // could sum into a double count.
  assert.doesNotMatch(sql, /interval/i);
});

// ---- Concurrency, retry, request count ---------------------------------------

test("never more than 2 PostHog requests in flight, and the cap is actually reached", async () => {
  const h = harness();
  await h.run();
  assert.equal(h.state.peakInFlight, 2, "cap must be reached, not merely never exceeded");
});

test("a clean run makes exactly 6 PostHog requests: 1 preflight + 5 metrics", async () => {
  const h = harness();
  await h.run();
  // Equality, so both an added query and a silently dropped one fail.
  assert.equal(h.state.posthogCalls, 6);
  assert.equal(h.state.queryNames.filter((q) => q === "weekly_digest_dev_ids").length, 1);
});

test("every query name carries the weekly_digest label, never daily_report", async () => {
  const h = harness();
  await h.run();
  assert.deepEqual(h.state.queryNames.slice().sort(), [
    "weekly_digest_app_usage",
    "weekly_digest_dev_ids",
    "weekly_digest_download_sources",
    "weekly_digest_downloads",
    "weekly_digest_onboard_activate",
    "weekly_digest_website",
  ]);
});

test("a 504 that then succeeds still produces a complete digest", async () => {
  let attempts = 0;
  const h = harness({ posthog: { website: () => {
    attempts += 1;
    return attempts === 1 ? fail(504) : ok(POSTHOG_ROWS.website);
  } } });
  const content = await h.run();
  assert.match(content, /EnviousWispr Weekly Digest/);
  assert.equal(attempts, 2);
  assert.equal(h.state.posts.length, 1);
  assert.match(h.state.posts[0].embeds[1].description, /119 people viewed 226 pages/);
});

// ---- Degrade: no number may appear when its query failed ----------------------

test("an exhausted section degrades, the others keep real numbers, one digest posts", async () => {
  const h = harness({ posthog: { website: () => fail(503) } });
  await assert.rejects(() => h.run(), /unavailable sections/);
  assert.equal(h.state.posts.length, 1, "exactly one digest, never a second notice");
  const [digest] = h.state.posts;
  const website = digest.embeds[1].description;
  assert.match(website, /temporarily unavailable/);
  // The degraded section must not fabricate a zero.
  assert.doesNotMatch(website, /\b0 people\b/);
  // Every other section still carries its real figures.
  assert.match(digest.embeds[3].description, /189 people used EnviousWispr/);
  assert.match(digest.embeds[0].description, /900 page views/);
});

test("a healthy run says 'temporarily unavailable' nowhere and prints no question marks", async () => {
  const h = harness();
  await h.run();
  const text = JSON.stringify(h.state.posts[0]);
  // Two-way control: without this, a degrade-everything bug passes every
  // failure test above.
  assert.doesNotMatch(text, /temporarily unavailable/);
  assert.doesNotMatch(text, /\?/);
});

// ---- dev_ids is an app-usage dependency, NOT a whole-run gate -----------------

test("dev_ids exhausted: app usage degrades, three sections still deliver", async () => {
  const h = harness({ posthog: { dev_ids: () => fail(503) } });
  await assert.rejects(() => h.run(), /unavailable sections/);
  assert.equal(h.state.posts.length, 1);
  const [digest] = h.state.posts;
  assert.match(digest.embeds[3].description, /temporarily unavailable/);
  assert.match(digest.embeds[0].description, /900 page views/);
  assert.match(digest.embeds[1].description, /119 people viewed/);
  // No app_usage query may be attempted without a resolved exclusion list.
  assert.equal(h.state.queryNames.includes("weekly_digest_app_usage"), false);
  // A partial digest was delivered, so the whole-run notice must NOT appear.
  assert.equal(h.state.posts.filter((p) => /could not be generated/.test(p.content || "")).length, 0);
});

test("dev_ids overflowing the id ceiling degrades app usage, never truncates the list", async () => {
  const many = { results: Array.from({ length: 5001 }, (_, i) => [`dev-${i}`]), columns: ["distinct_id"] };
  const h = harness({ posthog: { dev_ids: () => ok(many) } });
  await assert.rejects(() => h.run(), /unavailable sections/);
  assert.equal(h.state.posts.length, 1);
  assert.match(h.state.posts[0].embeds[3].description, /temporarily unavailable/);
  assert.equal(h.state.queryNames.includes("weekly_digest_app_usage"), false);
});

test("a dev_ids 401 costs app usage only; a METRIC 401 fails the whole run", async () => {
  const devAuth = harness({ posthog: { dev_ids: () => fail(401) } });
  await assert.rejects(() => devAuth.run(), /unavailable sections/);
  assert.equal(devAuth.state.posts.length, 1, "a partial digest still posts");
  assert.equal(devAuth.state.posts[0].embeds.length, 4);

  const metricAuth = harness({ posthog: { website: () => fail(401) } });
  await assert.rejects(() => metricAuth.run(), /HTTP 401/);
  // Contract failure: notice, no digest.
  assert.equal(metricAuth.state.posts.length, 1);
  assert.match(metricAuth.state.posts[0].content, /could not be generated/);
  assert.equal(metricAuth.state.posts[0].embeds, undefined);
});

test("a malformed metric response posts the failure notice and no digest", async () => {
  const h = harness({ posthog: { downloads: () => ok({ columns: ["intents"] }) } });
  await assert.rejects(() => h.run(), /returned no results array/);
  assert.equal(h.state.posts.length, 1);
  assert.match(h.state.posts[0].content, /could not be generated/);
  assert.equal(h.state.posts[0].embeds, undefined);
});

test("zero dev ids is a legitimate state and must not produce NOT IN ()", async () => {
  const h = harness({ posthog: { dev_ids: () => ok({ results: [], columns: ["distinct_id"] }) } });
  await h.run();
  const appUsage = h.state.sql.find((q) => q.includes("AS fresh"));
  assert.match(appUsage, /environment = 'production'/);
  assert.doesNotMatch(appUsage, /NOT IN \(\)/);
});

test("resolved dev ids reach the app-usage query as a literal exclusion list", async () => {
  const h = harness();
  await h.run();
  const appUsage = h.state.sql.find((q) => q.includes("AS fresh"));
  assert.match(appUsage, /distinct_id NOT IN \('dev-a', 'dev-b'\)/);
});

// ---- Trigger gate ------------------------------------------------------------

test("an unauthenticated trigger returns 401 and posts nothing", async () => {
  const res = await worker.fetch(new Request("https://w.dev/"), ENV);
  assert.equal(res.status, 401);
});

test("a wrong token is refused", async () => {
  const res = await worker.fetch(new Request("https://w.dev/?token=nope"), ENV);
  assert.equal(res.status, 401);
});

test("the query-string form is refused even when the value is CORRECT", async () => {
  // Header only: a secret in a URL survives in browser and shell history,
  // proxies and request logs, and leaking it restores the unauthenticated
  // Discord-posting access this gate closes.
  const res = await worker.fetch(new Request("https://w.dev/?token=s3cret"), ENV);
  assert.equal(res.status, 401);
});

test("the gate opens for the correct header, and only for that", () => {
  // Asserted on the gate FUNCTION, not by driving the handler. An earlier
  // version of this test called worker.fetch and checked for a non-401: with no
  // fetch injected it ran the real runDigest against production PostHog,
  // Cloudflare and GitHub on every CI run, and it would have passed on a 500.
  // A test that reaches production to prove a local branch is two defects.
  const req = (headers) => new Request("https://w.dev/", { headers });
  assert.equal(isAuthorizedTrigger(req({ "x-trigger-secret": "s3cret" }), ENV), true);
  assert.equal(isAuthorizedTrigger(req({ "x-trigger-secret": "wrong" }), ENV), false);
  assert.equal(isAuthorizedTrigger(req({}), ENV), false);
  // Fails closed with no secret configured, even when one is supplied.
  const { TRIGGER_SECRET, ...noSecret } = ENV;
  assert.equal(isAuthorizedTrigger(req({ "x-trigger-secret": "s3cret" }), noSecret), false);
  // And the query-string form is not a credential here at all.
  assert.equal(
    isAuthorizedTrigger(new Request("https://w.dev/?token=s3cret"), ENV), false);
});

test("an unset TRIGGER_SECRET refuses everything, including a supplied token", async () => {
  const { TRIGGER_SECRET, ...noSecret } = ENV;
  for (const url of ["https://w.dev/", "https://w.dev/?token=s3cret", "https://w.dev/?token="]) {
    const res = await worker.fetch(new Request(url), noSecret);
    assert.equal(res.status, 401, `${url} must fail closed`);
  }
  const withHeader = await worker.fetch(
    new Request("https://w.dev/", { headers: { "x-trigger-secret": "s3cret" } }), noSecret);
  assert.equal(withHeader.status, 401, "an unset secret must refuse the header form too");
});

test("a wrong header-form trigger secret is refused too", async () => {
  const res = await worker.fetch(
    new Request("https://w.dev/", { headers: { "x-trigger-secret": "wrong" } }),
    ENV
  );
  assert.equal(res.status, 401);
});

// ---- Cloudflare and GitHub ---------------------------------------------------

test("a Cloudflare failure degrades its section and never renders a zero", async () => {
  for (const bad of [
    () => fail(500),
    () => ok({ errors: [{ message: "boom" }] }),
    () => ok({ data: { viewer: { zones: [] } } }),
  ]) {
    const h = harness({ cloudflare: bad });
    await assert.rejects(() => h.run(), /unavailable sections/);
    const traffic = h.state.posts[0].embeds[0].description;
    assert.match(traffic, /temporarily unavailable/);
    // The shipped worker reported a confident 0 for each of these three.
    assert.doesNotMatch(traffic, /\b0 page views\b/);
  }
});

test("a genuine zero-traffic week still renders 0, not 'unavailable'", async () => {
  const empty = { data: { viewer: { zones: [{ totals: [], byDay: [] }] } } };
  const h = harness({ cloudflare: () => ok(empty) });
  await h.run();
  const traffic = h.state.posts[0].embeds[0].description;
  assert.match(traffic, /0 page views/);
  assert.doesNotMatch(traffic, /temporarily unavailable/);
});

test("all-time downloads reads every page, not just GitHub's first 30", async () => {
  const h = harness();
  await h.run();
  assert.deepEqual(h.state.githubPages, [1, 2]);
  // 100 releases on page 1 + 45 on page 2, one 10-download dmg each.
  assert.match(h.state.posts[0].embeds[2].description, /1,450 downloads all time/);
});

test("one page is one request: a short first page must not fetch a second", async () => {
  const h = harness({ github: () => ok(RELEASES_PAGE(45)) });
  await h.run();
  assert.deepEqual(h.state.githubPages, [1]);
  assert.match(h.state.posts[0].embeds[2].description, /450 downloads all time/);
});

test("a mid-pagination failure degrades the section rather than reporting a partial sum", async () => {
  const h = harness({ github: (page) => (page === 1 ? ok(RELEASES_PAGE(100)) : fail(502)) });
  await assert.rejects(() => h.run(), /unavailable sections/);
  const downloads = h.state.posts[0].embeds[2].description;
  assert.match(downloads, /temporarily unavailable/);
  // 1,000 is page one's real total, and exactly the plausible wrong number a
  // partial sum would have shipped.
  assert.doesNotMatch(downloads, /1,000 downloads/);
});

test("GitHub non-2xx on the first page degrades instead of returning '?'", async () => {
  const h = harness({ github: () => fail(403) });
  await assert.rejects(() => h.run(), /unavailable sections/);
  assert.match(h.state.posts[0].embeds[2].description, /temporarily unavailable/);
});

// ---- Payload -----------------------------------------------------------------

test("the digest posts four section embeds carrying the brand colour", async () => {
  const h = harness();
  await h.run();
  const [digest] = h.state.posts;
  assert.equal(digest.embeds.length, 4);
  assert.deepEqual(digest.embeds.map((e) => e.title), [
    "All website traffic", "Tracked visitor activity", "Downloads", "App usage",
  ]);
  for (const embed of digest.embeds) {
    assert.equal(embed.color, 0x7c3aed);
    assert.equal(embed.footer.text, "EnviousWispr Weekly Digest");
  }
  assert.match(digest.content, /EnviousWispr Weekly Digest, July 27 to August 2/);
});

test("the assembled payload passes the shared Discord validator at realistic size", async () => {
  const wide = {
    results: Array.from({ length: 8 }, (_, i) => ["unknown_referrer", 10_000_000 + i]),
    columns: ["bucket", "n"],
  };
  const h = harness({ posthog: { download_sources: () => ok(wide) } });
  await h.run();
  const [digest] = h.state.posts;
  const combined = digest.embeds.reduce(
    (sum, e) => sum + e.title.length + e.description.length + e.footer.text.length, 0);
  assert.ok(combined < 6000, `combined embed text ${combined} must stay under Discord's budget`);
});

test("the digest is sent exactly once, and nothing follows a successful delivery", async () => {
  const h = harness();
  await h.run();
  assert.equal(h.state.posts.length, 1);
});

// ---- Pure helpers ------------------------------------------------------------

test("sourceLabel: known maps, unknown/null -> Other", () => {
  assert.equal(sourceLabel("github_readme"), "GitHub README");
  assert.equal(sourceLabel("reddit"), "Reddit");
  assert.equal(sourceLabel("nope"), "Other");
  assert.equal(sourceLabel(null), "Other");
  assert.equal(sourceLabel(undefined), "Other");
  assert.equal(Object.keys(SOURCE_LABELS).length > 10, true);
});

test("formatSourceBreakdown: unavailable, genuine zero, and rows read differently", () => {
  assert.equal(formatSourceBreakdown(null), "Sources unavailable");
  assert.equal(formatSourceBreakdown(undefined), "Sources unavailable");
  assert.equal(formatSourceBreakdown([]), "No off-site downloads yet");
  assert.equal(
    formatSourceBreakdown([{ bucket: "reddit", n: 1234 }, { bucket: null, n: 2 }]),
    "Reddit: 1,234\nOther: 2"
  );
});

test("every formatter degrades to prose, never to a number, when its input is null", () => {
  for (const lines of [formatCloudflare(null), formatWebsite(null, null), formatDownloads(null, null, null), formatAppUsage(null, null)]) {
    assert.match(lines.join("\n"), /temporarily unavailable/);
  }
  // Title line must survive so the embed is still well-formed.
  assert.equal(formatAppUsage(null, null)[0], "App usage");
});

test("formatters produce a title line plus a non-empty body of strings", () => {
  const cases = [
    formatCloudflare({ totalPageViews: 1, summedDailyUniques: 2, totalRequests: 3, topCountries: [] }),
    formatWebsite({ views: 1, visitors: 2 }, 3),
    formatDownloads({ totalDownloads: 1, latestVersion: "v1" }, [], 0),
    formatAppUsage({ active: 1, fresh: 2 }, { onboarded: 1, activated: 1 }),
  ];
  for (const lines of cases) {
    assert.ok(lines.length >= 2);
    assert.ok(lines[0].length > 0);
    assert.ok(lines.slice(1).join("\n").length > 0);
    for (const line of lines) assert.equal(typeof line, "string");
  }
});

test("the Cloudflare visitor line says what it counts, not 'unique visitors'", () => {
  const lines = formatCloudflare({ totalPageViews: 900, summedDailyUniques: 300, totalRequests: 5000, topCountries: [] });
  const text = lines.join("\n");
  assert.match(text, /daily visits added up/);
  assert.match(text, /counts three times/);
  // The old label claimed people; the arithmetic never supported that.
  assert.doesNotMatch(text, /Unique Visitors/i);
});

test("fetchCloudflareStats and fetchGitHubDownloads are callable in isolation", async () => {
  const w = resolveWeekWindow(NOW);
  const cf = await fetchCloudflareStats(ENV, w, { fetchFn: async () => ok(CF_BODY) });
  assert.equal(cf.totalPageViews, 900);
  assert.deepEqual(cf.topCountries[0], ["United States", 3000]);
  const gh = await fetchGitHubDownloads(ENV, { fetchFn: async () => ok(RELEASES_PAGE(2)) });
  assert.equal(gh.totalDownloads, 20);
  assert.equal(gh.latestVersion, "v1.1.0");
});

// ---- Whole-diff review findings (#1589) --------------------------------------

test("an empty aggregate row is a failure, never a silently 'unavailable' success", async () => {
  // The trap this closes: the section renders "temporarily unavailable" while
  // the run RESOLVES, so a degraded digest reports success to the trigger and
  // broken telemetry looks healthy for as long as nobody reads the post.
  for (const [key, embedIndex] of [["website", 1], ["downloads", 2], ["app_usage", 3]]) {
    const h = harness({ posthog: { [key]: () => ok({ results: [], columns: [] }) } });
    // Message tightened in review round 2 from "returned no aggregate row" to
    // name the actual count; the CONTRACT is unchanged - it must fail the run.
    await assert.rejects(() => h.run(), /expected exactly 1 aggregate row, got 0/,
      `${key} returning no row must fail the run, not resolve it`);
    assert.equal(h.state.posts.length, 1);
    assert.match(h.state.posts[0].embeds[embedIndex].description, /temporarily unavailable/);
  }
});

test("download sources returning zero rows is a genuine empty week, not a failure", async () => {
  // The two-way control for the test above: a GROUP BY legitimately returns no
  // rows, and treating THAT as malformed would fail every quiet week.
  const h = harness({ posthog: { download_sources: () => ok({ results: [], columns: ["bucket", "n"] }) } });
  await h.run();
  assert.match(h.state.posts[0].embeds[2].description, /No off-site downloads yet/);
  assert.doesNotMatch(h.state.posts[0].embeds[2].description, /Sources unavailable/);
});

test("a Cloudflare 200 with a malformed zone degrades instead of reporting zeros", async () => {
  const malformed = [
    { data: { viewer: { zones: [{ byDay: [] }] } } },                       // no totals
    { data: { viewer: { zones: [{ totals: [] }] } } },                      // no byDay
    { data: { viewer: { zones: [{ totals: [{ sum: {} }], byDay: [] }] } } }, // no numbers
    { data: { viewer: { zones: [{ totals: [{ sum: { requests: "many", pageViews: 1 }, uniq: { uniques: 1 } }], byDay: [] }] } } },
  ];
  for (const body of malformed) {
    const h = harness({ cloudflare: () => ok(body) });
    await assert.rejects(() => h.run(), /unavailable sections/);
    const traffic = h.state.posts[0].embeds[0].description;
    assert.match(traffic, /temporarily unavailable/);
    assert.doesNotMatch(traffic, /\b0 page views\b/, "a malformed response must never render as zero");
  }
});

test("the download line does not claim to be a subset of tracked visitors", async () => {
  // `intents` counts EVENTS, including off-site redirects that never appeared
  // in the pageview population, so it can legitimately exceed the visitor
  // count. "N of them" claimed both a headcount and a subset.
  const h = harness({ posthog: {
    website: () => ok({ results: [[201, 105]], columns: ["views", "visitors"] }),
    downloads: () => ok({ results: [[400, 2]], columns: ["intents", "bots_excluded"] }),
  } });
  await h.run();
  const text = h.state.posts[0].embeds[1].description;
  assert.match(text, /400 downloads were started/);
  assert.doesNotMatch(text, /of them/);
  // The scenario that proves the point: more downloads than tracked visitors.
  assert.match(text, /105 people viewed/);
});

// ---- Whole-diff review round 2: a 200 with the wrong SHAPE ---------------------
// Third round on one class, so these enumerate every path where a successful
// response can still produce a number, not only the ones review named.

test("an aggregate row missing a column degrades instead of publishing NaN", async () => {
  const cases = [
    ["website", 1, { results: [[226]], columns: ["views"] }],                 // renamed/missing column
    ["downloads", 2, { results: [[36, null]], columns: ["intents", "bots_excluded"] }],
    ["app_usage", 3, { results: [["many", 51]], columns: ["active", "fresh"] }],
  ];
  for (const [key, embedIndex, body] of cases) {
    const h = harness({ posthog: { [key]: () => ok(body) } });
    await assert.rejects(() => h.run(), /missing or non-numeric/, `${key} must degrade`);
    const text = JSON.stringify(h.state.posts[0]);
    assert.doesNotMatch(text, /NaN/, "a malformed row must never reach the reader as NaN");
    assert.match(h.state.posts[0].embeds[embedIndex].description, /temporarily unavailable/);
  }
});

test("more than one aggregate row is malformed, not a first-row-wins guess", async () => {
  const h = harness({ posthog: { website: () => ok({ results: [[1, 2], [3, 4]], columns: ["views", "visitors"] }) } });
  await assert.rejects(() => h.run(), /expected exactly 1 aggregate row/);
  assert.match(h.state.posts[0].embeds[1].description, /temporarily unavailable/);
});

test("a non-numeric count in the sources breakdown degrades that section", async () => {
  const h = harness({ posthog: { download_sources: () => ok({ results: [["reddit", "lots"]], columns: ["bucket", "n"] }) } });
  // Message generalised in review round 4 when the bucket column joined the
  // same check; the CONTRACT is unchanged.
  await assert.rejects(() => h.run(), /malformed row shape/);
  assert.match(h.state.posts[0].embeds[2].description, /Sources unavailable/);
});

test("a GitHub asset with a non-numeric download_count degrades, never undercounts", async () => {
  const h = harness({ github: () => ok([{ tag_name: "v1.0.0", assets: [{ name: "a.dmg", download_count: null }] }]) });
  await assert.rejects(() => h.run(), /unavailable sections/);
  const text = h.state.posts[0].embeds[2].description;
  assert.match(text, /temporarily unavailable/);
  // `|| 0` would have silently reported this as a real zero-download release.
  assert.doesNotMatch(text, /0 downloads all time/);
});

test("a genuine zero-download release still counts as zero, not as malformed", async () => {
  // Two-way control for the check above.
  const h = harness({ github: () => ok([{ tag_name: "v1.0.0", assets: [{ name: "a.dmg", download_count: 0 }] }]) });
  await h.run();
  assert.match(h.state.posts[0].embeds[2].description, /0 downloads all time/);
});

test("a malformed dev-ID row degrades app usage rather than claiming a false exclusion", async () => {
  // `results: [[]]` yields undefined, which sqlIdList renders as the literal
  // 'undefined': the query would exclude an id nobody has, INCLUDE every real
  // dev machine, and the section would still say they were excluded. A wrong
  // number whose caveat is also a lie.
  for (const body of [
    { results: [[]], columns: ["distinct_id"] },
    { results: [[null]], columns: ["distinct_id"] },
    { results: [[""]], columns: ["distinct_id"] },
    { results: [[42]], columns: ["distinct_id"] },
  ]) {
    const h = harness({ posthog: { dev_ids: () => ok(body) } });
    await assert.rejects(() => h.run(), /unavailable sections/);
    assert.match(h.state.posts[0].embeds[3].description, /temporarily unavailable/);
    // The false claim must not be printed beside an unavailable section.
    assert.doesNotMatch(h.state.posts[0].embeds[3].description, /Dev machines are excluded/);
    assert.equal(h.state.queryNames.includes("weekly_digest_app_usage"), false);
    assert.equal(h.state.sql.some((q) => q.includes("'undefined'")), false);
  }
});

test("a source row with a missing or renamed bucket column degrades", async () => {
  // A NULL bucket is legitimate (no source recorded -> "Other"). An OMITTED or
  // renamed column arrives as undefined and would take that same branch,
  // publishing a confident attribution for a query whose shape had changed.
  for (const body of [
    { results: [[20]], columns: ["n"] },                       // bucket column gone
    { results: [["reddit", 8]], columns: ["source", "n"] },    // renamed
    { results: [[42, 8]], columns: ["bucket", "n"] },          // wrong type
  ]) {
    const h = harness({ posthog: { download_sources: () => ok(body) } });
    // Either detector may fire first: a renamed column trips the COLUMN check,
    // a wrong-typed value trips the ROW check. Both must degrade the section.
    await assert.rejects(() => h.run(), /malformed (row shape|column set)/);
    assert.match(h.state.posts[0].embeds[2].description, /Sources unavailable/);
    assert.doesNotMatch(h.state.posts[0].embeds[2].description, /Other:/);
  }
});

test("a genuinely null bucket is data, not a malformed row", async () => {
  // Two-way control: PostHog returns null for an absent property, and that is a
  // real "we could not attribute this download", rendered as Other.
  const h = harness({ posthog: { download_sources: () => ok({ results: [[null, 3]], columns: ["bucket", "n"] }) } });
  await h.run();
  assert.match(h.state.posts[0].embeds[2].description, /Other: 3/);
  assert.doesNotMatch(h.state.posts[0].embeds[2].description, /Sources unavailable/);
});

test("a release with a missing assets array degrades, never undercounts", async () => {
  // `rel.assets || []` treated this as a release with no downloads, quietly
  // lowering an all-time total that then passed every numeric check.
  const h = harness({ github: () => ok([{ tag_name: "v1.0.0" }]) });
  await assert.rejects(() => h.run(), /unavailable sections/);
  assert.match(h.state.posts[0].embeds[2].description, /temporarily unavailable/);
});

test("an asset with a non-string name degrades rather than being skipped", async () => {
  const h = harness({ github: () => ok([{ tag_name: "v1.0.0", assets: [{ name: null, download_count: 5 }] }]) });
  await assert.rejects(() => h.run(), /unavailable sections/);
  assert.match(h.state.posts[0].embeds[2].description, /temporarily unavailable/);
});

test("a release that genuinely ships no dmg is data, not a malformed response", async () => {
  // Two-way control for both checks above: an EMPTY assets array, and a
  // non-dmg asset, are both legitimate.
  const h = harness({ github: () => ok([
    { tag_name: "v1.1.0", assets: [] },
    { tag_name: "v1.0.0", assets: [{ name: "notes.txt", download_count: 3 }, { name: "a.dmg", download_count: 7 }] },
  ]) });
  await h.run();
  assert.match(h.state.posts[0].embeds[2].description, /7 downloads all time/);
});

test("a country entry without a name degrades instead of publishing 'undefined'", async () => {
  const body = { data: { viewer: { zones: [{
    totals: [{ sum: { requests: 10, pageViews: 5 }, uniq: { uniques: 3 } }],
    byDay: [{ sum: { countryMap: [{ requests: 10 }] } }],
  }] } } };
  const h = harness({ cloudflare: () => ok(body) });
  await assert.rejects(() => h.run(), /unavailable sections/);
  const traffic = h.state.posts[0].embeds[0].description;
  assert.match(traffic, /temporarily unavailable/);
  assert.doesNotMatch(traffic, /undefined/);
});

test("a day with no country traffic is legitimate and still reports the totals", async () => {
  // Two-way control: an absent countryMap is normal for a quiet day.
  const body = { data: { viewer: { zones: [{
    totals: [{ sum: { requests: 10, pageViews: 5 }, uniq: { uniques: 3 } }],
    byDay: [{ sum: {} }],
  }] } } };
  const h = harness({ cloudflare: () => ok(body) });
  await h.run();
  assert.match(h.state.posts[0].embeds[0].description, /5 page views/);
});

test("the app-usage line does not claim first-time installs it cannot prove", async () => {
  // is_fresh_install is `onboardingState != .completed`, so it stays true on
  // every launch until setup finishes. Measured: 46 reported vs 43 genuinely
  // first-launching in the same window. The sentence must not overclaim.
  const h = harness();
  await h.run();
  const text = h.state.posts[0].embeds[3].description;
  assert.match(text, /51 people began setting up\./);
  assert.match(text, /31 people finished setting up\. Of those, 24 also dictated\./);
  // The install number is launches-without-completed-onboarding, so it must not
  // claim first-time installs it cannot prove.
  assert.doesNotMatch(text, /installed it for the first time/);
});

test("the onboarding funnel reads install, setup, then first dictation", async () => {
  const h = harness();
  await h.run();
  const text = h.state.posts[0].embeds[3].description;
  assert.match(text, /189 people used EnviousWispr this week\./);
  assert.match(text, /51 people began setting up\./);
  assert.match(text, /31 people finished setting up\. Of those, 24 also dictated\./);
});

test("the activation subquery is dev-filtered by environment ONLY, never twice", async () => {
  const h = harness();
  await h.run();
  const sql = h.state.sql.find((q) => q.includes("onboarding.completed"));
  // The outer WHERE carries the full predicate, including the dev-id list.
  assert.match(sql, /WHERE event = 'onboarding\.completed' AND properties\.environment = 'production'/);
  assert.match(sql, /distinct_id NOT IN \('dev-a', 'dev-b'\)/);
  // The inner membership set carries environment only. Evaluating the unbounded
  // dev-exclusion a second time inside one query is the doubled-subquery shape
  // that timed out production PostHog in #1655 and #1716.
  assert.equal(sql.split("distinct_id NOT IN").length - 1, 1, "dev exclusion must appear exactly once");
  assert.match(sql, /dictation\.completed' AND properties\.result = 'success'\s*\n\s*AND properties\.environment = 'production'/);
});

test("the funnel degrades with app usage when dev ids cannot be resolved", async () => {
  const h = harness({ posthog: { dev_ids: () => fail(503) } });
  await assert.rejects(() => h.run(), /unavailable sections/);
  const text = h.state.posts[0].embeds[3].description;
  assert.match(text, /temporarily unavailable/);
  assert.equal(h.state.queryNames.includes("weekly_digest_onboard_activate"), false);
});

test("a failed funnel query leaves the usage line intact, and vice versa", async () => {
  const funnelDown = harness({ posthog: { onboard_activate: () => fail(503) } });
  await assert.rejects(() => funnelDown.run(), /unavailable sections/);
  const a = funnelDown.state.posts[0].embeds[3].description;
  assert.match(a, /189 people used EnviousWispr/);
  assert.match(a, /Setup and first-dictation figures were temporarily unavailable/);

  const usageDown = harness({ posthog: { app_usage: () => fail(503) } });
  await assert.rejects(() => usageDown.run(), /unavailable sections/);
  const b = usageDown.state.posts[0].embeds[3].description;
  assert.match(b, /31 people finished setting up/);
  assert.match(b, /The number of people who began setting up was temporarily unavailable/);
});

test("an EMPTY response with a malformed column set degrades, not 'none yet'", async () => {
  // The axis this closes: every row-shape check is skipped when there are zero
  // rows, which is exactly when a malformed empty response arrives. The digest
  // would otherwise report "No off-site downloads yet" with full confidence.
  for (const body of [{ results: [], columns: [] }, { results: [], columns: ["source", "count"] }]) {
    const h = harness({ posthog: { download_sources: () => ok(body) } });
    await assert.rejects(() => h.run(), /malformed column set/);
    assert.match(h.state.posts[0].embeds[2].description, /Sources unavailable/);
    assert.doesNotMatch(h.state.posts[0].embeds[2].description, /No off-site downloads yet/);
  }
});

test("an EMPTY dev-id response with no columns degrades app usage, never assumes zero", async () => {
  // Same axis in the shared resolver: `{results: [], columns: []}` read as "no
  // dev accounts", so both reports would fall back to the environment filter
  // and include dev machines while printing that they were excluded.
  const h = harness({ posthog: { dev_ids: () => ok({ results: [], columns: [] }) } });
  await assert.rejects(() => h.run(), /unavailable sections/);
  assert.match(h.state.posts[0].embeds[3].description, /temporarily unavailable/);
  assert.equal(h.state.queryNames.includes("weekly_digest_app_usage"), false);
});

test("a genuinely empty response WITH valid columns is still a real empty week", async () => {
  // Two-way control for both checks above.
  const h = harness({ posthog: {
    dev_ids: () => ok({ results: [], columns: ["distinct_id"] }),
    download_sources: () => ok({ results: [], columns: ["bucket", "n"] }),
  } });
  await h.run();
  assert.match(h.state.posts[0].embeds[2].description, /No off-site downloads yet/);
  assert.match(h.state.posts[0].embeds[3].description, /189 people used EnviousWispr/);
});

test("the usage headline counts successful DICTATORS, not launches", async () => {
  const h = harness();
  await h.run();
  const sql = h.state.sql.find((q) => q.includes("AS fresh"));
  // Founder definition: one successful dictation is what counts as using it.
  assert.match(sql, /uniqExactIf\(distinct_id, event = 'dictation\.completed' AND properties\.result = 'success'\) AS active/);
  assert.match(sql, /uniqExactIf\(distinct_id, event = 'onboarding\.started'\) AS fresh/);
  // One round trip over both event types, scoped so it does not scan everything.
  assert.match(sql, /WHERE event IN \('dictation\.completed', 'onboarding\.started'\)/);
});

test("dev ids are read by column NAME, not by position", async () => {
  // A response with distinct_id in a later column passed the name check and
  // then read the wrong column, excluding ids nobody has.
  const h = harness({ posthog: {
    dev_ids: () => ok({ results: [["2026-08-01", "dev-a"]], columns: ["day", "distinct_id"] }),
  } });
  await h.run();
  const sql = h.state.sql.find((q) => q.includes("AS fresh"));
  assert.match(sql, /NOT IN \('dev-a'\)/);
  assert.doesNotMatch(sql, /2026-08-01/);
});

test("the install line claims setup BEGAN, never that it was a first time", async () => {
  // Diagnostics has a "Restart Onboarding" action, so an existing user can emit
  // onboarding.started again. Claiming "for the first time" would be the same
  // overclaiming that made is_fresh_install misleading, in a new place.
  const h = harness();
  await h.run();
  const text = h.state.posts[0].embeds[3].description;
  assert.match(text, /51 people began setting up\./);
  assert.doesNotMatch(text, /first time/);
});
