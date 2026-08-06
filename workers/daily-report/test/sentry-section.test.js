// Tests for the Sentry transport (workers/shared/sentry.js) and the digest
// section policy (workers/reporting/sentry-section.js), issue #1965.
//
// They live in this package because workers/shared and workers/reporting have
// no test package of their own - the same arrangement posthog.js and discord.js
// already use, documented in workers/shared/README.md.
//
// Run: node --test (from workers/daily-report/)
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

import {
  SentryQueryError,
  SentryShapeError,
  SentryDeadlineError,
  discoverAggregate,
  issueList,
} from "../../shared/sentry.js";
import {
  ERROR_CATEGORIES,
  LOST,
  DEGRADED,
  SENTRY_CALLS_PER_DIGEST,
  DEFAULT_SECTION_BUDGET,
  classifyProblem,
  parseReleaseVersion,
  resolveReleaseLine,
  fetchSentrySection,
  formatSentrySection,
  formatSentryUnavailable,
} from "../../reporting/sentry-section.js";
import { DISCORD_LIMITS } from "../../shared/discord.js";

const ENV = {
  SENTRY_ORG: "envious-labs-llc",
  SENTRY_PROJECT_ID: "4511097112428544",
  SENTRY_PROJECT_SLUG: "enviouswispr",
  SENTRY_AUTH_TOKEN: "test-token",
};
const OPTS = { workerLabel: "test", sleepFn: async () => {} };
const WINDOW = {
  startISO: "2026-08-05T04:00:00",
  endISO: "2026-08-06T04:00:00",
  priorStartISO: "2026-08-04T04:00:00",
  firstSeenPeriod: "24h",
};

// ── Fake transport ──────────────────────────────────────────────────────────

/** Minimal Response stand-in. `body.cancel` is present because the real
 * transport cancels a failed body, and a double that omits it would make the
 * retry path throw for a reason production never sees. */
function response(status, payload, { headers = {} } = {}) {
  const lower = new Map(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: (name) => lower.get(String(name).toLowerCase()) ?? null },
    body: { cancel: async () => {} },
    json: async () => {
      if (payload === "not-json") throw new SyntaxError("bad json");
      return payload;
    },
  };
}

/** Aggregate body carrying meta.fields, which the REAL endpoint returns on an
 * empty response too (measured 2026-08-06). A double thinner than that would
 * hide the defect the shape check exists to catch. */
function aggregate(rows, fields) {
  const names = fields ?? Object.keys(rows[0] ?? {});
  return { data: rows, meta: { fields: Object.fromEntries(names.map((f) => [f, "integer"])) } };
}

/** Records every URL requested, so a call-count assertion measures the real
 * outbound behaviour rather than a summary the code reports about itself. */
function recorder(handler) {
  const urls = [];
  return {
    urls,
    fetchFn: async (url) => {
      urls.push(url);
      return handler(url, urls.length);
    },
  };
}

const RELEASE_ROWS = [
  { release: "com.enviouswispr.app@2.4.3", "count_unique(user)": 8, "count()": 19 },
  { release: "com.enviouswispr.app@2.4.1", "count_unique(user)": 3, "count()": 12 },
  { release: "com.enviouswispr.app@2.3.1", "count_unique(user)": 2, "count()": 5 },
  { release: "com.enviouswispr.app@2.4.0", "count_unique(user)": 2, "count()": 7 },
];

function problemRow(issue, category, users, events, level = "error") {
  return {
    issue,
    "issue.id": 1,
    title: `${category}: something`,
    "error.category": category,
    level,
    "count_unique(user)": users,
    "count()": events,
  };
}

const PROBLEM_FIELDS = ["title", "issue.id", "error.category", "level", "count_unique(user)", "count()"];

/** Routes each of the five calls by its query name, which is the only thing
 * that distinguishes them in the URL. */
function digestFetch({ releases = RELEASE_ROWS, problems = [], newIssues = [], people = 13, priorPeople = 12, headers = {} } = {}) {
  return recorder((url) => {
    if (url.includes("/issues/")) return response(200, newIssues);
    if (url.includes("field=release")) return response(200, aggregate(releases, ["release", "count_unique(user)", "count()"]));
    if (url.includes("field=issue")) {
      return response(200, aggregate(problems, PROBLEM_FIELDS), { headers });
    }
    // The two headline aggregates differ only by window.
    const isPrior = url.includes(encodeURIComponent(WINDOW.priorStartISO));
    return response(200, aggregate(
      [{ "count_unique(user)": isPrior ? priorPeople : people, "count()": 0 }],
      ["count_unique(user)", "count()"]
    ));
  });
}

// ── Classification completeness ─────────────────────────────────────────────

const HERE = dirname(fileURLToPath(import.meta.url));
const SWIFT_ENUM = resolve(HERE, "../../../Sources/EnviousWisprServices/SentryBreadcrumb.swift");

test("every ErrorCategory in the Swift enum is classified", () => {
  const source = readFileSync(SWIFT_ENUM, "utf8");
  // Scoped to the ErrorCategory declaration: the file contains other enums, and
  // a whole-file scan would demand classifications for cases that are not
  // error categories at all.
  const start = source.indexOf("public enum ErrorCategory: String");
  assert.ok(start !== -1, "ErrorCategory declaration not found - this test's parse is broken, not the map");
  const end = source.indexOf("\n  }", start);
  assert.ok(end !== -1, "ErrorCategory declaration has no closing brace - parse is broken");
  const raws = [...source.slice(start, end).matchAll(/case\s+\w+\s*=\s*"([a-z_]+)"/g)].map((m) => m[1]);

  // POSITIVE CONTROL. A regex that silently matches nothing would make this
  // whole test vacuous and it would pass forever. 27 is the measured count on
  // 2026-08-06; a genuine addition to the app should RAISE this, and the
  // assertion below is what forces this table to be updated with it.
  assert.ok(raws.length >= 27, `expected at least 27 categories, parsed ${raws.length}`);

  const missing = raws.filter((raw) => !Object.hasOwn(ERROR_CATEGORIES, raw));
  assert.deepEqual(missing, [], `unclassified ErrorCategory values: ${missing.join(", ")}`);

  const extra = Object.keys(ERROR_CATEGORIES).filter((k) => !raws.includes(k));
  assert.deepEqual(extra, [], `classified values that no longer exist in Swift: ${extra.join(", ")}`);
});

test("every classification declares a group, a label and a delivery claim", () => {
  for (const [raw, entry] of Object.entries(ERROR_CATEGORIES)) {
    assert.ok(entry.group === LOST || entry.group === DEGRADED, `${raw}: bad group`);
    assert.equal(typeof entry.label, "string", `${raw}: missing label`);
    assert.ok(entry.label.length > 0, `${raw}: empty label`);
    assert.equal(typeof entry.deliveryProven, "boolean", `${raw}: missing deliveryProven`);
    assert.equal(typeof entry.emitted, "boolean", `${raw}: missing emitted`);
    // A degraded row asserts the user still got their text. That claim is never
    // allowed to be the conservative default.
    if (entry.group === DEGRADED) {
      assert.equal(entry.deliveryProven, true, `${raw}: degraded requires proven delivery`);
    }
  }
});

test("the three unemitted categories are marked unemitted and classified conservatively", () => {
  for (const raw of ["availability_check_failed", "fallback_failed", "state_mismatch"]) {
    assert.equal(ERROR_CATEGORIES[raw].emitted, false, raw);
    assert.equal(ERROR_CATEGORIES[raw].group, LOST, raw);
  }
});

test("grounded-review corrections stay corrected", () => {
  // Each of these was LOST in an earlier draft and was corrected against its
  // producer. A regression here is silent in production: it just moves a row
  // between two headings the founder reads as very different things.
  assert.equal(ERROR_CATEGORIES.recovery_key_store_failed.group, DEGRADED);
  assert.equal(ERROR_CATEGORIES.hotkey_registration_failed.group, DEGRADED);
  assert.equal(ERROR_CATEGORIES.paste_failed.group, DEGRADED);
  // Conservative, because their producers disagree and no indexed field splits them.
  assert.equal(ERROR_CATEGORIES.xpc_service_error.deliveryProven, false);
  assert.equal(ERROR_CATEGORIES.model_load_wedged.deliveryProven, false);
  assert.equal(ERROR_CATEGORIES.pipeline_dispatch_failed.deliveryProven, false);
});

test("classifyProblem: unknown, blank-fatal and blank-error are three different answers", () => {
  // Two-way: a known category must NOT take the unknown path.
  assert.equal(classifyProblem({ category: "paste_failed", level: "error" }).group, DEGRADED);

  const unknown = classifyProblem({ category: "brand_new_category", level: "error" });
  assert.equal(unknown.group, LOST);
  assert.equal(unknown.label, "brand_new_category", "an unknown category must show its raw name");
  assert.equal(unknown.deliveryProven, false);

  // The measured real shape: an unhandled crash carries no category at all.
  const crash = classifyProblem({ category: "", level: "fatal", title: "EXC_BAD_ACCESS:  timed out after  >" });
  assert.equal(crash.group, LOST);
  assert.equal(crash.label, "app crash (EXC_BAD_ACCESS)");
  assert.equal(crash.deliveryProven, false);
  // THE MESSAGE HALF NEVER APPEARS. It is the one place user-derived text could
  // reach Discord, and the split-at-first-colon is what keeps it out by
  // construction rather than by trusting Sentry's redaction.
  assert.doesNotMatch(crash.label, /timed out/);

  // A blank category that is NOT fatal must not be called a crash.
  const blank = classifyProblem({ category: null, level: "error" });
  assert.equal(blank.group, LOST);
  assert.notEqual(blank.label, "app crash");
});

// ── Release line ────────────────────────────────────────────────────────────

test("parseReleaseVersion refuses anything that is not a three-part version", () => {
  assert.deepEqual(parseReleaseVersion("com.enviouswispr.app@2.4.3"), [2, 4, 3]);
  assert.deepEqual(parseReleaseVersion("2.4.3"), [2, 4, 3]);
  for (const bad of ["com.enviouswispr.app@2.4", "2.4.3.1", "v2.4.3", "2.4.x", "", null, 243]) {
    assert.equal(parseReleaseVersion(bad), null, `should refuse ${String(bad)}`);
  }
});

test("resolveReleaseLine picks the minor line of the release with the most people", () => {
  const line = resolveReleaseLine(RELEASE_ROWS);
  assert.equal(line.floor, "2.4.0");
  // 2.3.1 is the only release below the line, with 2 people.
  assert.equal(line.tailPeople, 2);
});

test("resolveReleaseLine does not cliff on release day", () => {
  // 2.5.0 just shipped and almost nobody is on it. The line must stay on 2.4,
  // or the section would report near-nothing exactly when a new build most
  // needs watching.
  const line = resolveReleaseLine([
    { release: "com.enviouswispr.app@2.5.0", "count_unique(user)": 1, "count()": 1 },
    { release: "com.enviouswispr.app@2.4.3", "count_unique(user)": 9, "count()": 30 },
  ]);
  assert.equal(line.floor, "2.4.0");
  assert.equal(line.tailPeople, 0, "a newer release is never part of the tail");
});

test("resolveReleaseLine breaks ties toward the newer version", () => {
  const line = resolveReleaseLine([
    { release: "com.enviouswispr.app@2.3.9", "count_unique(user)": 5, "count()": 5 },
    { release: "com.enviouswispr.app@2.4.0", "count_unique(user)": 5, "count()": 5 },
  ]);
  assert.equal(line.floor, "2.4.0");
});

test("resolveReleaseLine ignores malformed releases and returns null when none are usable", () => {
  const line = resolveReleaseLine([
    { release: "garbage", "count_unique(user)": 99, "count()": 99 },
    { release: "com.enviouswispr.app@2.4.3", "count_unique(user)": 1, "count()": 1 },
  ]);
  assert.equal(line.floor, "2.4.0", "a malformed release must not win the ranking");
  assert.equal(resolveReleaseLine([{ release: "garbage", "count_unique(user)": 5 }]), null);
  assert.equal(resolveReleaseLine([]), null);
});

// ── Transport ───────────────────────────────────────────────────────────────

test("discoverAggregate rejects a 200 whose meta.fields is missing", async () => {
  // THE case this check exists for: zero rows is a legitimate answer, so any
  // per-row validation is skipped exactly when a malformed empty body arrives,
  // and the section would print "no errors" for an unknown truth.
  const { fetchFn } = recorder(() => response(200, { data: [] }));
  await assert.rejects(
    () => discoverAggregate(ENV, {
      queryName: "q", fields: ["count()"], requiredFields: ["count()"], statsPeriod: "24h",
    }, { ...OPTS, fetchFn }),
    SentryShapeError
  );
});

test("discoverAggregate accepts a legitimately empty result that carries meta.fields", async () => {
  // The two-way control for the test above: without it, a check that rejected
  // EVERY empty response would pass the first test while breaking quiet days.
  const { fetchFn } = recorder(() => response(200, aggregate([], ["count()"])));
  const result = await discoverAggregate(ENV, {
    queryName: "q", fields: ["count()"], requiredFields: ["count()"], statsPeriod: "24h",
  }, { ...OPTS, fetchFn });
  assert.deepEqual(result.rows, []);
  assert.equal(result.truncated, false);
});

test("discoverAggregate rejects a missing required field, a non-array data and a non-object row", async () => {
  const cases = [
    aggregate([], ["count()"]),                       // requiredFields asks for more
    { data: "nope", meta: { fields: { "count_unique(user)": "integer" } } },
    { data: [null], meta: { fields: { "count_unique(user)": "integer" } } },
  ];
  for (const payload of cases) {
    const { fetchFn } = recorder(() => response(200, payload));
    await assert.rejects(
      () => discoverAggregate(ENV, {
        queryName: "q", fields: ["count_unique(user)"], requiredFields: ["count_unique(user)"], statsPeriod: "24h",
      }, { ...OPTS, fetchFn }),
      SentryShapeError
    );
  }
});

test("discoverAggregate retries a 429 and gives up as a query error, never a zero", async () => {
  let attempts = 0;
  const { fetchFn } = recorder(() => {
    attempts += 1;
    return response(429, {});
  });
  await assert.rejects(
    () => discoverAggregate(ENV, {
      queryName: "q", fields: ["count()"], statsPeriod: "24h",
    }, { ...OPTS, fetchFn }),
    (err) => err instanceof SentryQueryError && err.status === 429
  );
  assert.equal(attempts, 2, "two attempts total, bounded by Cloudflare's 50-subrequest cap");
});

test("discoverAggregate does NOT retry a 403", async () => {
  // A 403 on the org events endpoint is a permanent scope problem, measured on
  // both worker tokens 2026-08-06. Retrying it burns the window and reports the
  // same thing three attempts later.
  let attempts = 0;
  const { fetchFn } = recorder(() => {
    attempts += 1;
    return response(403, {});
  });
  await assert.rejects(
    () => discoverAggregate(ENV, { queryName: "q", fields: ["count()"], statsPeriod: "24h" }, { ...OPTS, fetchFn }),
    (err) => err instanceof SentryQueryError && err.status === 403
  );
  assert.equal(attempts, 1);
});

test("discoverAggregate refuses a 200 that is not JSON", async () => {
  const { fetchFn } = recorder(() => response(200, "not-json"));
  await assert.rejects(
    () => discoverAggregate(ENV, { queryName: "q", fields: ["count()"], statsPeriod: "24h" }, { ...OPTS, fetchFn }),
    SentryShapeError
  );
});

test("discoverAggregate demands exactly one window form", async () => {
  const { fetchFn } = recorder(() => response(200, aggregate([], ["count()"])));
  for (const params of [
    { queryName: "q", fields: ["count()"] },                                             // neither
    { queryName: "q", fields: ["count()"], statsPeriod: "24h", start: "a", end: "b" },    // both
  ]) {
    await assert.rejects(() => discoverAggregate(ENV, params, { ...OPTS, fetchFn }), TypeError);
  }
});

test("discoverAggregate stops at the caller's deadline instead of sleeping past it", async () => {
  const { fetchFn } = recorder(() => response(429, {}));
  await assert.rejects(
    () => discoverAggregate(ENV, { queryName: "q", fields: ["count()"], statsPeriod: "24h" },
      { ...OPTS, fetchFn, deadlineAt: Date.now() + 5 }),
    SentryDeadlineError
  );
});

test("discoverAggregate refuses to run without configuration", async () => {
  const { fetchFn } = recorder(() => response(200, aggregate([], ["count()"])));
  for (const env of [{ ...ENV, SENTRY_AUTH_TOKEN: "" }, { ...ENV, SENTRY_ORG: "" }]) {
    await assert.rejects(
      () => discoverAggregate(env, { queryName: "q", fields: ["count()"], statsPeriod: "24h" }, { ...OPTS, fetchFn }),
      TypeError
    );
  }
});

test("discoverAggregate requires a workerLabel with no default", async () => {
  // A default would file one worker's Sentry reads under another's name.
  const { fetchFn } = recorder(() => response(200, aggregate([], ["count()"])));
  await assert.rejects(
    () => discoverAggregate(ENV, { queryName: "q", fields: ["count()"], statsPeriod: "24h" }, { fetchFn }),
    TypeError
  );
});

test("issueList refuses a row without a shortId", async () => {
  const { fetchFn } = recorder(() => response(200, [{ firstSeen: "2026-08-06T00:00:00Z" }]));
  await assert.rejects(
    () => issueList(ENV, { queryName: "q" }, { ...OPTS, fetchFn }),
    SentryShapeError
  );
});

test("issueList suppresses the per-issue stats array it never reads", async () => {
  const { fetchFn, urls } = recorder(() => response(200, []));
  await issueList(ENV, { queryName: "q" }, { ...OPTS, fetchFn });
  assert.match(urls[0], /statsPeriod=(&|$)/, "statsPeriod must be empty to drop the stats payload");
});

// ── The section end to end ──────────────────────────────────────────────────

test("fetchSentrySection issues exactly the budgeted number of calls", async () => {
  const { fetchFn, urls } = digestFetch({ problems: [problemRow("EW-1", "paste_failed", 3, 4)] });
  await fetchSentrySection(ENV, WINDOW, { ...OPTS, fetchFn });
  assert.equal(urls.length, SENTRY_CALLS_PER_DIGEST);
});

test("the call count does not move with problem volume", async () => {
  // The constraint that actually matters: no path may fan out per issue. A
  // hundred problems must cost exactly what one costs.
  const many = Array.from({ length: 100 }, (_, i) => problemRow(`EW-${i}`, "paste_failed", 1, 1));
  const { fetchFn, urls } = digestFetch({ problems: many });
  await fetchSentrySection(ENV, WINDOW, { ...OPTS, fetchFn });
  assert.equal(urls.length, SENTRY_CALLS_PER_DIGEST);
});

test("the badge marks only the genuinely-new issue", async () => {
  // The control that killed the original min(timestamp) design: a long-lived
  // issue that is ACTIVE in the window must not badge.
  const { fetchFn } = digestFetch({
    problems: [
      problemRow("EW-OLD", "paste_failed", 5, 9),
      problemRow("EW-NEW", "", 1, 4, "fatal"),
    ],
    newIssues: [{ shortId: "EW-NEW", firstSeen: "2026-08-06T12:07:21Z" }],
  });
  const data = await fetchSentrySection(ENV, WINDOW, { ...OPTS, fetchFn });
  assert.equal(data.rows.find((r) => r.shortId === "EW-OLD").isNew, false);
  assert.equal(data.rows.find((r) => r.shortId === "EW-NEW").isNew, true);
});

test("the section scopes its problem query to the resolved release line", async () => {
  const { fetchFn, urls } = digestFetch({ problems: [problemRow("EW-1", "paste_failed", 1, 1)] });
  await fetchSentrySection(ENV, WINDOW, { ...OPTS, fetchFn });
  const problemUrl = urls.find((u) => u.includes("field=issue"));
  assert.match(decodeURIComponent(problemUrl), /release\.version:>=2\.4\.0/);
});

test("total events is derived from the rows and matches their sum", async () => {
  const { fetchFn } = digestFetch({
    problems: [problemRow("EW-1", "paste_failed", 3, 19), problemRow("EW-2", "asr_failed", 2, 4)],
  });
  const data = await fetchSentrySection(ENV, WINDOW, { ...OPTS, fetchFn });
  assert.equal(data.events, 23);
});

test("a non-numeric count is a defect, never a zero", async () => {
  const { fetchFn } = digestFetch({ problems: [problemRow("EW-1", "paste_failed", "n/a", 4)] });
  await assert.rejects(() => fetchSentrySection(ENV, WINDOW, { ...OPTS, fetchFn }), TypeError);
});

test("no usable release line reports a measurement failure, not good news", async () => {
  const { fetchFn } = digestFetch({ releases: [{ release: "garbage", "count_unique(user)": 4 }] });
  const data = await fetchSentrySection(ENV, WINDOW, { ...OPTS, fetchFn });
  assert.equal(data.empty, true);
  assert.equal(data.reason, "no-release-line");
  const lines = formatSentrySection(data, { title: "Sentry" });
  assert.match(lines.join("\n"), /could not be matched to a release/);
  assert.doesNotMatch(lines.join("\n"), /No errors/);
});

test("window fields are required, including the first-seen period", async () => {
  const { fetchFn } = digestFetch();
  for (const key of ["startISO", "endISO", "priorStartISO", "firstSeenPeriod"]) {
    const broken = { ...WINDOW, [key]: undefined };
    await assert.rejects(() => fetchSentrySection(ENV, broken, { ...OPTS, fetchFn }), TypeError, key);
  }
});

test("the first-seen period reaches the query verbatim", async () => {
  const { fetchFn, urls } = digestFetch({ problems: [problemRow("EW-1", "paste_failed", 1, 1)] });
  await fetchSentrySection(ENV, { ...WINDOW, firstSeenPeriod: "7d" }, { ...OPTS, fetchFn });
  const issuesUrl = urls.find((u) => u.includes("/issues/"));
  assert.match(decodeURIComponent(issuesUrl), /firstSeen:-7d/);
});

// ── Presentation ────────────────────────────────────────────────────────────

async function render(overrides, formatOpts = {}) {
  const { fetchFn } = digestFetch(overrides);
  const data = await fetchSentrySection(ENV, WINDOW, { ...OPTS, fetchFn });
  return { data, lines: formatSentrySection(data, { title: "Sentry, yesterday", ...formatOpts }) };
}

test("the section groups lost from degraded and never prints a rate", async () => {
  const { lines } = await render({
    problems: [
      problemRow("EW-1", "audio_capture_stalled", 7, 19),
      problemRow("EW-2", "paste_failed", 1, 1),
    ],
  });
  const text = lines.join("\n");
  assert.match(text, /LOST THE DICTATION/);
  assert.match(text, /STILL WORKED, JUST WORSE/);
  assert.match(text, /7 people {3}microphone capture stalled/);
  assert.match(text, /1 person {3}paste fell back to the clipboard/);
  assert.match(text, /Impact rate unavailable/);
  assert.doesNotMatch(text, /\d+(\.\d+)?%/, "the section must never print a percentage");
});

test("a conservative row says delivery is not proven and a proven one does not", async () => {
  const { lines } = await render({
    problems: [
      problemRow("EW-1", "xpc_service_error", 2, 2),
      problemRow("EW-2", "audio_capture_stalled", 2, 2),
    ],
  });
  const text = lines.join("\n");
  assert.match(text, /transcription helper failed, delivery not proven/);
  assert.match(text, /2 people {3}microphone capture stalled(\n|$)/);
});

test("the crash row reads as a crash exactly once", async () => {
  const { lines } = await render({ problems: [problemRow("EW-1", "", 1, 4, "fatal")] });
  const text = lines.join("\n");
  assert.match(text, /1 person {3}app crash, delivery not proven/);
  assert.equal(text.match(/delivery not proven/g).length, 1);
});

test("the people delta is stated in both directions and when flat", async () => {
  const up = await render({ problems: [problemRow("EW-1", "asr_failed", 1, 1)], people: 13, priorPeople: 12 });
  assert.match(up.lines.join("\n"), /1 more than the previous period \(12 people\)/);

  const down = await render({ problems: [problemRow("EW-1", "asr_failed", 1, 1)], people: 10, priorPeople: 12 });
  assert.match(down.lines.join("\n"), /2 fewer than the previous period/);

  const flat = await render({ problems: [problemRow("EW-1", "asr_failed", 1, 1)], people: 12, priorPeople: 12 });
  assert.match(flat.lines.join("\n"), /the same as the previous period/);
});

test("the old-build tail is reported as an upper bound", async () => {
  const { lines } = await render({ problems: [problemRow("EW-1", "asr_failed", 1, 1)] });
  // Non-additive per-release counts, so it must not claim a distinct-person count.
  assert.match(lines.join("\n"), /up to 2 people on builds older than 2\.4\.0/);
});

test("zero problems renders an explicit good-news line", async () => {
  const { data, lines } = await render({ problems: [] });
  assert.equal(data.empty, true);
  assert.equal(lines.length, 2);
  assert.match(lines[1], /No errors were recorded on current versions/);
});

test("unavailable copy says nothing was measured and leaks nothing technical", () => {
  const lines = formatSentryUnavailable("Sentry, yesterday");
  assert.equal(lines.length, 2);
  assert.match(lines[1], /not a report of zero/);
  for (const line of lines) {
    assert.doesNotMatch(line, /http|token|401|403|sentry\.io/i);
  }
});

test("a formatter without a title is refused rather than silently untitled", () => {
  assert.throws(() => formatSentrySection({ empty: true }, {}), TypeError);
  assert.throws(() => formatSentryUnavailable(""), TypeError);
});

test("an over-budget section discloses what it omitted instead of truncating silently", async () => {
  const many = Array.from({ length: 60 }, (_, i) => problemRow(`EW-${i}`, "audio_capture_stalled", 2, 2));
  const { lines } = await render({ problems: many });
  const text = lines.join("\n");
  assert.match(text, /more problems are not listed here\. The totals above include them\./);
  assert.ok(text.length <= DEFAULT_SECTION_BUDGET + 200, `description ${text.length} should stay near its budget`);
});

test("a full page of problems is disclosed as a limited breakdown", async () => {
  const many = Array.from({ length: 100 }, (_, i) => problemRow(`EW-${i}`, "asr_failed", 1, 1));
  const { lines } = await render({ problems: many });
  assert.match(lines.join("\n"), /breakdown covers the largest 100 only/);
});

test("a full page issues no second Sentry request", async () => {
  const many = Array.from({ length: 100 }, (_, i) => problemRow(`EW-${i}`, "asr_failed", 1, 1));
  const { fetchFn, urls } = digestFetch({ problems: many, headers: { link: 'rel="next"; results="true"' } });
  await fetchSentrySection(ENV, WINDOW, { ...OPTS, fetchFn });
  assert.equal(urls.length, SENTRY_CALLS_PER_DIGEST, "pagination must never buy another page");
});

test("the worst realistic section still fits Discord's per-embed limits", async () => {
  // Maximum-length labels, both groups populated, badges on, tail line present.
  const many = Array.from({ length: 100 }, (_, i) =>
    problemRow(`EW-${i}`, i % 2 ? "a_very_long_unknown_category_name_that_renders_raw" : "paste_failed", 999, 9999));
  const { fetchFn } = digestFetch({
    problems: many,
    newIssues: many.map((_, i) => ({ shortId: `EW-${i}`, firstSeen: "2026-08-06T00:00:00Z" })),
    people: 99999,
    priorPeople: 1,
  });
  const data = await fetchSentrySection(ENV, WINDOW, { ...OPTS, fetchFn });
  const lines = formatSentrySection(data, { title: "Sentry, last 7 days" });
  const [title, ...body] = lines;
  assert.ok(title.length <= DISCORD_LIMITS.embedTitle);
  assert.ok(body.join("\n").length <= DISCORD_LIMITS.embedDescription);
  // And well inside the shared 6000 budget, so it cannot crowd out the other
  // sections and take the whole report down with it.
  assert.ok(body.join("\n").length <= DEFAULT_SECTION_BUDGET + 200);
});

test("a crash label carries the exception type and never the message", () => {
  // Two different crashes must not render as two identical rows. A live smoke
  // run printed exactly that before the type was included.
  const a = classifyProblem({ category: "", level: "fatal", title: "EXC_BAD_ACCESS:  timed out after  >" });
  const b = classifyProblem({ category: "", level: "fatal", title: "NSInternalInconsistencyException: [REDACTED]" });
  assert.notEqual(a.label, b.label);
  assert.equal(b.label, "app crash (NSInternalInconsistencyException)");

  // Any title shape this code does not recognise falls back to the plain label
  // rather than printing something unexamined.
  for (const title of [
    undefined, null, "", ":no type", "a message with no colon at all and spaces",
    "Type With Spaces: msg", `${"A".repeat(60)}: msg`, "<script>: msg",
  ]) {
    const label = classifyProblem({ category: "", level: "fatal", title }).label;
    assert.ok(label === "app crash" || /^app crash \([A-Za-z_][A-Za-z0-9_.]*\)$/.test(label),
      `unexpected crash label for ${JSON.stringify(title)}: ${label}`);
    assert.doesNotMatch(label, /msg/);
  }
});

test("two problems that would render identically are separated by their issue id", async () => {
  // The live-smoke defect: two distinct NSInternalInconsistencyException
  // fingerprints, one person each, rendering as two identical lines.
  const { lines } = await render({
    problems: [
      problemRow("EW-34", "", 1, 4, "fatal"),
      problemRow("EW-3V", "", 1, 1, "fatal"),
      problemRow("EW-2C", "audio_capture_stalled", 5, 9),
    ],
  });
  const text = lines.join("\n");
  // These fixtures carry no exception type, so both land on the bare "app
  // crash" label and the issue id is the ONLY thing separating them.
  assert.match(text, /1 person {3}app crash EW-34, delivery not proven/);
  assert.match(text, /1 person {3}app crash EW-3V, delivery not proven/);
  // The row that does NOT collide keeps its clean label, so the id is a
  // targeted disambiguation rather than noise on every line.
  assert.match(text, /5 people {3}microphone capture stalled(\n|$)/);
});

test("a collision straddling the two groups is still disambiguated", () => {
  // Applied before the groups split, because a per-group pass cannot see a
  // collision whose halves land under different headings. Contrived, since a
  // label maps to one group today, but the pass must not depend on that.
  const data = {
    empty: false, floor: "2.4.0", tailPeople: 0, people: 2, priorPeople: 2, events: 2, truncated: false,
    rows: [
      { shortId: "EW-A", people: 1, events: 1, group: LOST, label: "same thing", deliveryProven: true, isNew: false },
      { shortId: "EW-B", people: 1, events: 1, group: DEGRADED, label: "same thing", deliveryProven: true, isNew: false },
    ],
  };
  const text = formatSentrySection(data, { title: "Sentry" }).join("\n");
  assert.match(text, /same thing EW-A/);
  assert.match(text, /same thing EW-B/);
});
