// Tests for the rate-alert (spike) path, issue #1965.
// Run: node --test  (from workers/sentry-triage/)
//
// The end-to-end cases drive the REAL `handleTriage` entry point with a real
// metric-issue payload, rather than calling the spike helpers directly. A
// harness that reassembled the flow would prove only that the copy works, and
// the whole defect being fixed here is that a metric payload took the WRONG
// branch inside that entry point.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  handleTriage,
  isMetricIssue,
  decideSpike,
  summarizeSpike,
  buildSpikeEmbed,
  buildSpikeFailOpenEmbed,
} from "../src/index.js";

const NOW = 1_800_000_000_000;
const HOUR = 3600_000;

function fakeKV(seed = {}) {
  const store = new Map(Object.entries(seed));
  return {
    store,
    async get(key) { return store.get(key) ?? null; },
    async put(key, value) { store.set(key, value); },
    async delete(key) { store.delete(key); },
  };
}

/** The real shape Sentry sends for a metric-alert firing: issueCategory
 * "metric", userCount 0, no release, no error.category. Every one of those is
 * why scoring it as an error produced the empty card. */
function metricPayload(overrides = {}) {
  return JSON.stringify({
    action: "created",
    data: {
      issue: {
        id: "7654321",
        shortId: "ENVIOUSWISPR-1H",
        title: "Errors above 5 an hour",
        permalink: "https://envious-labs-llc.sentry.io/issues/7654321/",
        level: "error",
        issueCategory: "metric",
        issueType: "metric_issue",
        userCount: 0,
        count: "0",
        ...overrides,
      },
    },
  });
}

const AGG_FIELDS = ["title", "issue.id", "error.category", "release", "environment", "count()", "count_unique(user)"];

function sentryResponse(rows) {
  return {
    ok: true,
    status: 200,
    headers: { get: () => null },
    body: { cancel: async () => {} },
    json: async () => ({
      data: rows,
      meta: { fields: Object.fromEntries(AGG_FIELDS.map((f) => [f, "integer"])) },
    }),
  };
}

function row(issue, category, release, environment, events, people) {
  return {
    issue,
    "issue.id": 1,
    title: `${category}: something`,
    "error.category": category,
    release,
    environment,
    "count()": events,
    "count_unique(user)": people,
  };
}

const SPIKE_ROWS = [
  row("EW-2C", "audio_capture_stalled", "com.enviouswispr.app@2.4.3", "production", 40, 6),
  row("EW-2C", "audio_capture_stalled", "com.enviouswispr.app@2.4.1", "production", 10, 3),
  row("EW-24", "paste_failed", "com.enviouswispr.app@2.4.3", "production", 8, 4),
  row("EW-99", "asr_failed", "com.enviouswispr.app@2.4.3-dev", "development", 5, 1),
];

/** Drives handleTriage with a stubbed fetch, recording every outbound call and
 * every Discord embed. */
function harness({ kv = fakeKV(), sentry = () => sentryResponse(SPIKE_ROWS), discordStatus = 204 } = {}) {
  const realFetch = globalThis.fetch;
  const requests = [];
  const embeds = [];
  globalThis.fetch = async (url, init) => {
    const target = String(url);
    requests.push(target);
    if (target.startsWith("https://us.sentry.io")) return sentry(target);
    if (target.startsWith("https://discord.test")) {
      embeds.push(JSON.parse(init.body).embeds[0]);
      // `ok` is what postDiscord actually reads. A double that returned only a
      // status made every delivery look like an http_non_2xx failure while
      // reporting httpStatus 204 - a double THINNER than the real Response,
      // which is the space these defects hide in.
      return { ok: discordStatus >= 200 && discordStatus < 300, status: discordStatus };
    }
    throw new Error(`unexpected fetch to ${target}`);
  };
  const env = {
    SENTRY_DEDUP: kv,
    SENTRY_AUTH_TOKEN: "token",
    SENTRY_PROJECT_ID: "4511097112428544",
    DISCORD_WEBHOOK_URL: "https://discord.test/hook",
  };
  return { env, kv, requests, embeds, restore: () => (globalThis.fetch = realFetch) };
}

// ── Recognition ─────────────────────────────────────────────────────────────

test("isMetricIssue recognises a rate alert and does NOT claim an ordinary error", () => {
  assert.equal(isMetricIssue({ issueCategory: "metric" }), true);
  assert.equal(isMetricIssue({ issueType: "metric_issue" }), true);
  // Two-way. A path that fires on everything would pass the first two lines
  // while routing every real crash away from the error handling.
  assert.equal(isMetricIssue({ issueCategory: "error", issueType: "error" }), false);
  assert.equal(isMetricIssue({}), false);
  assert.equal(isMetricIssue(null), false);
});

test("a metric payload DOES carry data.issue, which is why the old guard never fired", async () => {
  // The premise of the whole fix, asserted rather than assumed: the shipped
  // comment claimed metric alerts had no data.issue and were skipped. If that
  // were true this fixture would be unreachable.
  const payload = JSON.parse(metricPayload());
  assert.ok(payload.data.issue, "a metric alert carries data.issue");
  assert.equal(payload.data.issue.userCount, 0, "and no user count to score");
});

// ── Throttle policy ─────────────────────────────────────────────────────────

test("decideSpike enforces six hours on its own key, ignoring priority and regression", () => {
  assert.equal(decideSpike({ throttleLookup: { status: "complete", value: null }, now: NOW }).post, true);

  const fresh = { status: "complete", value: { lastNotifiedAt: NOW - 5 * HOUR, priority: "spike" } };
  assert.equal(decideSpike({ throttleLookup: fresh, now: NOW }).post, false);

  const expired = { status: "complete", value: { lastNotifiedAt: NOW - 6 * HOUR, priority: "spike" } };
  assert.equal(decideSpike({ throttleLookup: expired, now: NOW }).post, true);
});

test("a throttle READ failure fails open, exactly as the error path does", () => {
  for (const status of ["unavailable", "malformed", undefined]) {
    const r = decideSpike({ throttleLookup: { status }, now: NOW });
    assert.equal(r.post, true, `status ${status} must not suppress`);
    assert.equal(r.reason, "throttle-unavailable-failopen");
  }
});

test("a regressed metric issue is still throttled, unlike a regressed error", async () => {
  // THE case the generic policy cannot serve. A metric issue flips to
  // substatus "regressed" on EVERY firing, and rule 7's regression bypass would
  // therefore post every single time. That is the triple-buzz this fixes.
  const kv = fakeKV({ "spike:7654321": JSON.stringify({ lastNotifiedAt: NOW - HOUR, priority: "spike" }) });
  const h = harness({ kv });
  try {
    await handleTriage(metricPayload({ substatus: "regressed" }), h.env);
    assert.equal(h.embeds.length, 0, "a regressed metric issue inside the window must not post");
    assert.equal(h.requests.length, 0, "and must not spend a Sentry call to find that out");
  } finally {
    h.restore();
  }
});

test("the spike throttle lives on its own key and cannot collide with an error issue", async () => {
  // An error issue with the SAME id has key `sentry:<id>`; the spike uses
  // `spike:<id>`. A shared key would let one evict the other's window.
  const kv = fakeKV({ "sentry:7654321": JSON.stringify({ lastNotifiedAt: NOW, priority: "P1" }) });
  const h = harness({ kv });
  try {
    await handleTriage(metricPayload(), h.env);
    assert.equal(h.embeds.length, 1, "an unrelated error throttle must not suppress the spike");
    assert.ok(h.kv.store.has("spike:7654321"), "the spike writes its own key");
    assert.equal(
      JSON.parse(h.kv.store.get("sentry:7654321")).priority, "P1",
      "and leaves the error key untouched"
    );
  } finally {
    h.restore();
  }
});

// ── Summarisation ───────────────────────────────────────────────────────────

test("summarizeSpike sums events, never distinct users", () => {
  const s = summarizeSpike(SPIKE_ROWS);
  assert.equal(s.totalEvents, 63);
  assert.equal(s.devEvents, 5);
  assert.equal(s.realEvents, 58);
  // audio_capture_stalled spans two releases: 40 + 10 events, and people is the
  // LARGEST single row (6), never 6 + 3. The same person can appear under both.
  const top = s.problems[0];
  assert.equal(top.label, "audio_capture_stalled");
  assert.equal(top.events, 50);
  assert.equal(top.atLeastPeople, 6, "people is a lower bound, never a sum");
  // `displayVersion` is this worker's established owner of version display and
  // normalises `2.4.3-dev` to `2.4.3`, so the dev build collapses into its
  // release line here. That is not a lost signal: the "Real vs dev" field
  // carries the dev split explicitly, and it is the field that answers the
  // question. Using a second version formatter just for this card would be a
  // competing authority.
  assert.deepEqual(s.releases, ["2.4.1", "2.4.3"]);
});

test("an unlabelled environment counts as dev, the conservative direction", () => {
  // Attributing an unknown event to real users would turn the founder's own
  // testing into a user-facing incident.
  const s = summarizeSpike([row("EW-1", "asr_failed", "com.enviouswispr.app@2.4.3", undefined, 7, 1)]);
  assert.equal(s.devEvents, 7);
  assert.equal(s.realEvents, 0);
});

test("summarizeSpike skips a malformed count rather than treating it as zero", () => {
  const s = summarizeSpike([
    row("EW-1", "asr_failed", "com.enviouswispr.app@2.4.3", "production", "lots", 1),
    row("EW-2", "paste_failed", "com.enviouswispr.app@2.4.3", "production", 3, 1),
  ]);
  assert.equal(s.totalEvents, 3, "a malformed row contributes nothing, and never a fabricated 0 total");
  assert.equal(s.problems.length, 1);
});

test("a blank category falls back to the title's type, never to an empty label", () => {
  const s = summarizeSpike([
    { issue: "EW-1", title: "EXC_BAD_ACCESS:  timed out after  >", "error.category": "",
      release: "com.enviouswispr.app@2.4.3", environment: "production", "count()": 4, "count_unique(user)": 1 },
  ]);
  assert.equal(s.problems[0].label, "EXC_BAD_ACCESS");
});

test("summarizeSpike over no rows is an honest zero, not a crash", () => {
  const s = summarizeSpike([]);
  assert.deepEqual(s, { totalEvents: 0, devEvents: 0, realEvents: 0, problems: [], releases: [] });
});

// ── The card ────────────────────────────────────────────────────────────────

test("the enriched card names the problems, versions and dev split", async () => {
  const h = harness();
  try {
    await handleTriage(metricPayload(), h.env);
    assert.equal(h.embeds.length, 1, "one buzz, not three");
    const embed = h.embeds[0];
    assert.equal(embed.title, "[Sentry Spike] 63 errors in the last hour");
    const byName = Object.fromEntries(embed.fields.map((f) => [f.name, f.value]));
    assert.equal(byName["Real vs dev"], "58 from real users, 5 from dev builds");
    // `displayVersion` normalises a dev build into its release line, so the dev
    // events show up in "Real vs dev" rather than as a separate version string.
    assert.equal(byName.Versions, "2.4.1, 2.4.3");
    assert.match(byName["What is driving it"], /50 × audio_capture_stalled \(at least 6 people\)/);
    assert.match(byName["What is driving it"], /8 × paste_failed \(at least 4 people\)/);
    // The three things the OLD card said, which is what made it useless.
    const rendered = JSON.stringify(embed);
    assert.doesNotMatch(rendered, /unknown\/unknown/);
    assert.doesNotMatch(rendered, /0 user\(s\)/);
  } finally {
    h.restore();
  }
});

test("the spike costs exactly ONE Sentry call and keeps dev events", async () => {
  const h = harness();
  try {
    await handleTriage(metricPayload(), h.env);
    const sentry = h.requests.filter((u) => u.startsWith("https://us.sentry.io"));
    assert.equal(sentry.length, 1, "one call, never a per-issue fan-out");
    const url = decodeURIComponent(sentry[0]);
    assert.match(url, /statsPeriod=1h/, "the trailing hour, matching what the rule measures");
    // The digests force production-only; this one must NOT, by founder decision.
    assert.doesNotMatch(url, /environment=/, "dev events are counted deliberately");
  } finally {
    h.restore();
  }
});

test("a Sentry failure still buzzes once, and says the breakdown is missing", async () => {
  const h = harness({
    sentry: () => ({ ok: false, status: 403, headers: { get: () => null }, body: { cancel: async () => {} } }),
  });
  try {
    await handleTriage(metricPayload(), h.env);
    assert.equal(h.embeds.length, 1, "a rate alert is never lost to a lookup failure");
    assert.match(JSON.stringify(h.embeds[0]), /breakdown could not be read/);
  } finally {
    h.restore();
  }
});

test("an empty breakdown fails open rather than claiming zero errors", async () => {
  // The enriched card would otherwise read "0 errors in the last hour" beside
  // an alert that fired because there were more than five.
  const h = harness({ sentry: () => sentryResponse([]) });
  try {
    await handleTriage(metricPayload(), h.env);
    assert.equal(h.embeds.length, 1);
    assert.doesNotMatch(h.embeds[0].title, /0 errors/);
    assert.match(JSON.stringify(h.embeds[0]), /breakdown could not be read/);
  } finally {
    h.restore();
  }
});

test("a failed Discord delivery writes no throttle, so the next firing stays eligible", async () => {
  const h = harness({ discordStatus: 500 });
  try {
    await handleTriage(metricPayload(), h.env);
    assert.equal(h.kv.store.has("spike:7654321"), false);
  } finally {
    h.restore();
  }
});

test("a confirmed delivery writes the throttle", async () => {
  const h = harness();
  try {
    await handleTriage(metricPayload(), h.env);
    const stored = JSON.parse(h.kv.store.get("spike:7654321"));
    assert.equal(typeof stored.lastNotifiedAt, "number");
  } finally {
    h.restore();
  }
});

test("an ordinary error issue never takes the spike path", async () => {
  // The two-way control for the routing. Without it, a branch that captured
  // every payload would pass every test above while silently disabling the
  // per-issue error alerting this worker exists for.
  const h = harness();
  try {
    const errorPayload = JSON.stringify({
      action: "created",
      data: {
        issue: {
          id: "111", shortId: "EW-1", title: "asr_failed: X", permalink: "https://s/1",
          level: "error", issueCategory: "error", issueType: "error", userCount: 3, count: "9",
        },
      },
    });
    await handleTriage(errorPayload, { ...h.env, GITHUB_REPO: "o/r" });
    for (const embed of h.embeds) {
      assert.doesNotMatch(embed.title, /Sentry Spike/, "an error must not render as a spike");
    }
    assert.equal(h.kv.store.has("spike:111"), false, "and must not write a spike throttle");
  } finally {
    h.restore();
  }
});

test("the fail-open card never renders an empty title", () => {
  const embed = buildSpikeFailOpenEmbed({ issueId: "1", title: "", permalink: "https://s/1" });
  assert.ok(embed.title.length > "[Sentry Spike] ".length);
});

test("the card truncates a runaway breakdown instead of exceeding Discord's field limit", () => {
  const many = Array.from({ length: 200 }, (_, i) =>
    row(`EW-${i}`, `category_${i}_${"x".repeat(40)}`, "com.enviouswispr.app@2.4.3", "production", 5, 1));
  const embed = buildSpikeEmbed(summarizeSpike(many), { issueId: "1", title: "t", permalink: "https://s/1" });
  for (const field of embed.fields) {
    assert.ok(field.value.length <= 1024, `field ${field.name} is ${field.value.length} chars, over Discord's 1024 limit`);
  }
  assert.ok(embed.title.length <= 256);
});
