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
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

import {
  SentryQueryError,
  SentryShapeError,
  SentryDeadlineError,
  SentryNetworkError,
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
  windowInstant,
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

/** Every Swift source concatenated, so a producer search sees the whole app
 * rather than one declaration file. */
function readAllSwift(dir) {
  return readdirSync(dir, { recursive: true })
    .filter((name) => String(name).endsWith(".swift"))
    .map((name) => readFileSync(resolve(dir, String(name)), "utf8"))
    .join("\n");
}

test("every ErrorCategory in the Swift enum is classified", () => {
  const source = readFileSync(SWIFT_ENUM, "utf8");
  // Scoped to the ErrorCategory declaration: the file contains other enums, and
  // a whole-file scan would demand classifications for cases that are not
  // error categories at all.
  const start = source.indexOf("public enum ErrorCategory: String");
  assert.ok(start !== -1, "ErrorCategory declaration not found - this test's parse is broken, not the map");
  const end = source.indexOf("\n  }", start);
  assert.ok(end !== -1, "ErrorCategory declaration has no closing brace - parse is broken");
  // Parses BOTH forms Swift allows, and proves it saw every one.
  //
  // Two rounds of review went into this line. `[a-z_]+` could not match a raw
  // value containing a hyphen or a digit. Widening to `[^"]+` fixed that and
  // still missed a case with an IMPLICIT raw value - `case newCategory`, whose
  // raw value is its own name - which is legal Swift and would have been
  // invisible while the 27 lower bound still passed.
  //
  // The count check is what makes this non-vacuous: it compares what the
  // detailed pattern matched against a plain count of `case` lines, so a third
  // unparsed form fails loudly instead of silently shrinking the enum.
  const enumBody = source.slice(start, end);
  const declarations = [...enumBody.matchAll(/^\s*case\s+(\w+)(?:\s*=\s*"([^"]+)")?\s*$/gm)];
  const caseLines = enumBody.match(/^\s*case\b/gm) || [];
  assert.equal(declarations.length, caseLines.length,
    "an ErrorCategory declaration was not parsed - the parser is incomplete, not the enum");
  const raws = declarations.map(([, name, explicitRaw]) => explicitRaw ?? name);

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

test("the unemitted categories have no producer in the app, not just a flag saying so", () => {
  // Checking the hand-written `emitted` flag alone proves nothing: adding a
  // real producer in Swift would leave the flag lying and this test green. So
  // the claim is re-derived from the source every run.
  // The WHOLE source tree, not the enum's own file. Producers live in the
  // pipeline and services modules; the declaration file merely lists the cases.
  // Scoping this to SWIFT_ENUM made every assertion below vacuous, and the
  // positive control at the bottom is what caught it.
  const source = readAllSwift(resolve(HERE, "../../../Sources"));
  for (const raw of ["availability_check_failed", "fallback_failed", "state_mismatch"]) {
    assert.equal(ERROR_CATEGORIES[raw].emitted, false, raw);
    assert.equal(ERROR_CATEGORIES[raw].group, LOST, raw);
    const swiftCase = raw.replace(/_([a-z])/g, (_, c) => c.toUpperCase());
    const uses = source.match(new RegExp(`\\.${swiftCase}\\b`, "g")) || [];
    assert.equal(uses.length, 0, `${raw} now has a producer; reclassify it and clear emitted:false`);
  }
  // POSITIVE CONTROL for the search itself. A search that matched nothing would
  // make every assertion above vacuous and would pass forever.
  assert.ok((source.match(/\.modelLoadFailed\b/g) || []).length > 0,
    "the producer search matched nothing at all - the search is broken, not the map");
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
  // The sleep THROWS rather than no-opping. With a no-op sleep, moving the
  // deadline check to after the sleep passes this test while burning the
  // caller's whole remaining budget in a wait that could not have helped.
  let slept = false;
  const sleepFn = async () => { slept = true; throw new Error("slept past the deadline"); };
  const { fetchFn } = recorder(() => response(429, {}));
  await assert.rejects(
    () => discoverAggregate(ENV, { queryName: "q", fields: ["count()"], statsPeriod: "24h" },
      { ...OPTS, fetchFn, sleepFn, deadlineAt: Date.now() + 5 }),
    SentryDeadlineError
  );
  assert.equal(slept, false, "the deadline must be checked BEFORE the backoff sleep");
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
    // firstSeen INSIDE the reported window. The section re-checks the boundary
    // locally, so a fixture outside it would not badge however Sentry answered.
    newIssues: [{ shortId: "EW-NEW", firstSeen: "2026-08-05T12:07:21Z" }],
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

test("every window field is required", async () => {
  const { fetchFn } = digestFetch();
  for (const key of ["startISO", "endISO", "priorStartISO"]) {
    const broken = { ...WINDOW, [key]: undefined };
    await assert.rejects(() => fetchSentrySection(ENV, broken, { ...OPTS, fetchFn }), TypeError, key);
  }
});

test("the badge window is ABSOLUTE and matches the reported window", async () => {
  // `firstSeen:-24h` is measured from NOW, and neither report runs at the
  // instant its window closes, so the relative form straddles the window in
  // both directions. Measured live: `firstSeen:-5d` returned 3 issues where the
  // equivalent absolute range returned 4.
  const { fetchFn, urls } = digestFetch({ problems: [problemRow("EW-1", "paste_failed", 1, 1)] });
  await fetchSentrySection(ENV, WINDOW, { ...OPTS, fetchFn });
  const issuesUrl = new URL(urls.find((u) => u.includes("/issues/")));
  assert.equal(issuesUrl.searchParams.get("start"), WINDOW.startISO);
  assert.equal(issuesUrl.searchParams.get("end"), WINDOW.endISO);
  const query = issuesUrl.searchParams.get("query") || "";
  assert.match(query, /firstSeen:>=2026-08-05T04:00:00/);
  assert.match(query, /firstSeen:<2026-08-06T04:00:00/);
  assert.doesNotMatch(query, /firstSeen:-/, "the relative form must be gone");
});

test("an issue Sentry returns from OUTSIDE the window is still not badged", async () => {
  // The local boundary re-check. If Sentry's search semantics ever change, this
  // degrades to a MISSING badge rather than a wrong one.
  const { fetchFn } = digestFetch({
    problems: [problemRow("EW-OLD", "paste_failed", 1, 1)],
    newIssues: [{ shortId: "EW-OLD", firstSeen: "2026-07-02T00:00:00Z" }],
  });
  const data = await fetchSentrySection(ENV, WINDOW, { ...OPTS, fetchFn });
  assert.equal(data.rows[0].isNew, false);
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
  // STRICT. A "near its budget" tolerance is what let a real 24-character
  // overrun pass: the disclosure line was appended after the budget was already
  // spent. The budget governs the DESCRIPTION, so the title is excluded.
  const description = lines.slice(1).join("\n");
  assert.ok(description.length <= DEFAULT_SECTION_BUDGET,
    `description ${description.length} exceeds the ${DEFAULT_SECTION_BUDGET} budget`);
});

test("a full page of problems is disclosed as a limited breakdown", async () => {
  const many = Array.from({ length: 100 }, (_, i) => problemRow(`EW-${i}`, "asr_failed", 1, 1));
  const { lines } = await render({ problems: many });
  assert.match(lines.join("\n"), /the error count and the breakdown cover the largest 100 only/);
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
  assert.ok(body.join("\n").length <= DEFAULT_SECTION_BUDGET);
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

test("the description never exceeds its budget, at any problem count", async () => {
  // Swept rather than spot-checked: the overrun appeared only at counts where
  // the rows filled the budget exactly and the disclosure line then pushed past
  // it, which a single fixture size can miss entirely.
  for (const n of [1, 2, 3, 5, 8, 13, 21, 34, 40, 45, 50, 55, 60, 80, 100]) {
    const problems = Array.from({ length: n }, (_, i) =>
      problemRow(`EW-${i}`, i % 3 === 0 ? "audio_capture_stalled" : "paste_failed", 2, 2));
    const { lines } = await render({ problems });
    const description = lines.slice(1).join("\n");
    assert.ok(description.length <= DEFAULT_SECTION_BUDGET,
      `${n} problems produced a ${description.length}-character description`);
    assert.ok(description.length <= DISCORD_LIMITS.embedDescription);
  }
});

test("rows that share an issue id, or have none, are still told apart", () => {
  // The issue id is the meaningful separator, and it is NOT always sufficient.
  // Two rows with the same id and two with no id both rendered as identical
  // lines under the first version of this pass.
  const row = (shortId, label, group = LOST) =>
    ({ shortId, people: 1, events: 1, group, label, deliveryProven: true, isNew: false });
  const data = {
    empty: false, floor: "2.4.0", tailPeople: 0, people: 2, priorPeople: 1, events: 4, truncated: false,
    rows: [row("EW-X", "same"), row("EW-X", "same"), row(null, "none", DEGRADED), row(null, "none", DEGRADED)],
  };
  const body = formatSentrySection(data, { title: "Sentry" }).slice(1);
  const rendered = body.filter((l) => l.startsWith("  1 person"));
  assert.equal(rendered.length, 4, "all four rows render");
  assert.equal(new Set(rendered).size, 4, `four rows must render as four distinct lines, got ${JSON.stringify(rendered)}`);
});

test("a count that is not a non-negative integer is refused, never coerced", async () => {
  // Number() is far too permissive to validate with: null, "", false and []
  // are all 0, and ["7"] is 7. A single-element array reading as a person
  // count is the dangerous one, because it is silent and plausible.
  for (const bad of [null, "", false, [], ["7"], "  ", 1.5, -1, "3", {}]) {
    const { fetchFn } = digestFetch({ problems: [problemRow("EW-1", "paste_failed", bad, 4)] });
    await assert.rejects(() => fetchSentrySection(ENV, WINDOW, { ...OPTS, fetchFn }), TypeError,
      `people count ${JSON.stringify(bad)} must be refused`);
  }
  // Two-way: a genuine zero is a real answer and must NOT be refused.
  const { fetchFn } = digestFetch({ problems: [problemRow("EW-1", "paste_failed", 0, 0)] });
  const data = await fetchSentrySection(ENV, WINDOW, { ...OPTS, fetchFn });
  assert.equal(data.rows[0].people, 0);
});

test("a release row with a junk user count cannot win the release-line ranking", () => {
  // Number(["7"]) is 7, so an array once out-ranked a real release.
  const line = resolveReleaseLine([
    { release: "com.enviouswispr.app@2.2.0", "count_unique(user)": ["99"] },
    { release: "com.enviouswispr.app@2.4.3", "count_unique(user)": 1 },
  ]);
  assert.equal(line.floor, "2.4.0");
  assert.equal(line.tailPeople, 0, "and cannot contribute to the tail either");
});

// ── Privacy, retries and shapes the reviewer found untested ─────────────────

test("a raw network error never carries its message across the privacy boundary", async () => {
  // Both digest workers put `err.message` into their HTTP trigger response, and
  // the weekly one also records it in its failure summary. A fetch or runtime
  // error carrying a URL fragment would escape there, and the URL is the one
  // part of a Sentry request that contains search terms.
  const leaked = "https://us.sentry.io/api/0/x?query=release:secret-thing token=abcd1234";
  await assert.rejects(
    () => discoverAggregate(ENV, { queryName: "q", fields: ["count()"], statsPeriod: "24h" },
      { ...OPTS, fetchFn: async () => { throw new Error(leaked); } }),
    (err) =>
      err instanceof SentryNetworkError &&
      !err.message.includes("sentry.io") &&
      !err.message.includes("secret-thing") &&
      !err.message.includes("abcd1234")
  );
});

test("a retry that then succeeds returns the real answer", async () => {
  // The retry path was only ever tested to exhaustion, so a bug that dropped a
  // successful second attempt would not have shown up.
  let attempt = 0;
  const { fetchFn } = recorder(() => {
    attempt += 1;
    return attempt === 1 ? response(503, {}) : response(200, aggregate([{ "count()": 7 }], ["count()"]));
  });
  const result = await discoverAggregate(ENV, {
    queryName: "q", fields: ["count()"], requiredFields: ["count()"], statsPeriod: "24h",
  }, { ...OPTS, fetchFn });
  assert.equal(attempt, 2);
  assert.deepEqual(result.rows, [{ "count()": 7 }]);
});

test("issueList refuses a non-array body and an unusable firstSeen", async () => {
  for (const body of [{ issues: [] }, "nope", null, [{ shortId: "EW-1" }], [{ shortId: "EW-1", firstSeen: "soon" }]]) {
    const { fetchFn } = recorder(() => response(200, body));
    await assert.rejects(
      () => issueList(ENV, { queryName: "q" }, { ...OPTS, fetchFn }),
      SentryShapeError,
      `body ${JSON.stringify(body)} must be refused`
    );
  }
});

test("issueList demands start and end together, never one alone", async () => {
  const { fetchFn } = recorder(() => response(200, []));
  for (const params of [
    { queryName: "q", start: "2026-08-05T00:00:00" },
    { queryName: "q", end: "2026-08-06T00:00:00" },
  ]) {
    await assert.rejects(() => issueList(ENV, params, { ...OPTS, fetchFn }), TypeError);
  }
});

test("an unusable release line stops after the two stage-one calls", async () => {
  // The remaining three cannot be scoped honestly, and an unscoped answer would
  // silently re-admit every fixed bug on every old build.
  const { fetchFn, urls } = digestFetch({ releases: [{ release: "garbage", "count_unique(user)": 4 }] });
  const data = await fetchSentrySection(ENV, WINDOW, { ...OPTS, fetchFn });
  assert.equal(data.empty, true);
  assert.equal(urls.length, 2, "stage two must not run without a resolved floor");
});

test("the truncated headline says 'at least', and never claims the totals are complete", async () => {
  // `events` is summed from the returned rows, so on a truncated page it
  // EXCLUDES everything past the first hundred. Printing it as the total
  // understates it, and the old disclosure then said the totals included them.
  const many = Array.from({ length: 100 }, (_, i) => problemRow(`EW-${i}`, "asr_failed", 1, 1));
  const { lines } = await render({ problems: many });
  const text = lines.join("\n");
  assert.match(text, /at least \d+ errors across 100 or more problems/);
  assert.doesNotMatch(text, /The totals above include them/);
  assert.match(text, /The affected-people total covers all of them/);
});

test("an untruncated section still says the totals include the omitted rows", async () => {
  // Two-way control: the qualifier above must apply ONLY when truncated, or the
  // section would hedge a number it knows exactly.
  const many = Array.from({ length: 60 }, (_, i) => problemRow(`EW-${i}`, "asr_failed", 1, 1));
  const { lines } = await render({ problems: many });
  const text = lines.join("\n");
  assert.match(text, /The totals above include them/);
  assert.doesNotMatch(text, /at least/);
});

test("the section's Discord cap matches the transport's own limit", () => {
  // The cap is duplicated as a number rather than imported across the
  // policy/transport boundary, so this is what stops the two drifting apart.
  // The empty-section render that used to sit here was vacuous: its output is a
  // fixed two lines, so it fits any cap. The 300-row test below is the real one.
  assert.equal(DISCORD_LIMITS.embedDescription, 4096);
});

test("a budget that is not a positive safe integer is refused, never obeyed", async () => {
  // NaN makes every `> budget` comparison FALSE, so it disabled every check
  // silently: review rendered a 21,824-character description that way.
  const { fetchFn } = digestFetch({ problems: [problemRow("EW-1", "paste_failed", 1, 1)] });
  const data = await fetchSentrySection(ENV, WINDOW, { ...OPTS, fetchFn });
  for (const bad of [Number.NaN, Infinity, -1, 0, 1.5, "1200", null]) {
    assert.throws(() => formatSentrySection(data, { title: "Sentry", budget: bad }), TypeError,
      `budget ${String(bad)} must be refused`);
  }
});

// ── Gaps a mutation sweep found, each with the mutation it now kills ────────

test("window instants are read as UTC, whatever the machine's timezone", () => {
  // Tested on the HELPER, not through the section: a boundary fixture driven
  // end to end passes trivially on a UTC runner and can only fail on a
  // developer's machine, which is the wrong way round. Sentry reads these
  // strings as UTC; Date.parse without a zone reads them as LOCAL time.
  assert.equal(windowInstant("2026-08-05T04:00:00"), Date.UTC(2026, 7, 5, 4, 0, 0));
  assert.equal(windowInstant("2026-01-01T00:00:00"), Date.UTC(2026, 0, 1, 0, 0, 0));
  assert.throws(() => windowInstant("not a date"), TypeError);
});

test("a release component too large to be exact is refused, not ordered", () => {
  // Past 2^53 a component loses precision and compares equal to its
  // neighbours, so the ordering would be arbitrary rather than merely odd.
  assert.equal(parseReleaseVersion("app@9007199254740993.0.0"), null);
  assert.equal(parseReleaseVersion("app@1.99999999999999999.0"), null);
  // Two-way: an ordinary large-but-exact version still parses.
  assert.deepEqual(parseReleaseVersion("app@2.40.100"), [2, 40, 100]);

  // And such a release cannot win the ranking or join the tail.
  const line = resolveReleaseLine([
    { release: "app@9007199254740993.0.0", "count_unique(user)": 99 },
    { release: "com.enviouswispr.app@2.4.3", "count_unique(user)": 1 },
  ]);
  assert.equal(line.floor, "2.4.0");
  assert.equal(line.tailPeople, 0);
});

test("a generous caller cannot push the description past Discord's own limit", async () => {
  // The cap only bites when there is enough content to exceed 4096, so this
  // renders enough rows to get there. An uncapped budget would be obeyed and
  // the whole payload refused at delivery.
  const many = Array.from({ length: 300 }, (_, i) =>
    problemRow(`EW-${i}`, `a_long_category_name_number_${i}_${"x".repeat(30)}`, 3, 3));
  const { fetchFn } = digestFetch({ problems: many });
  const data = await fetchSentrySection(ENV, WINDOW, { ...OPTS, fetchFn });
  const description = formatSentrySection(data, { title: "Sentry", budget: 99999 }).slice(1).join("\n");
  assert.ok(description.length > DEFAULT_SECTION_BUDGET, "the fixture must actually exceed the default budget");
  assert.ok(description.length <= DISCORD_LIMITS.embedDescription,
    `description ${description.length} exceeds Discord's ${DISCORD_LIMITS.embedDescription} limit`);
});

test("the prior aggregate ends exactly where the reported window begins", () => {
  // Asserted against the REAL request rather than by restating the window
  // object back to itself. The version this replaces assigned the value it then
  // compared, so it could not fail for any input.
  return (async () => {
    const { fetchFn, urls } = digestFetch({ problems: [problemRow("EW-1", "paste_failed", 1, 1)] });
    await fetchSentrySection(ENV, WINDOW, { ...OPTS, fetchFn });
    const parsed = urls.map((u) => new URL(u));
    const prior = parsed.find((u) => u.searchParams.get("start") === WINDOW.priorStartISO);
    assert.ok(prior, "no request was made over the prior window");
    assert.equal(prior.searchParams.get("end"), WINDOW.startISO,
      "the prior window must end where the reported one starts");
    // And the reported window is the one everything else measures.
    const current = parsed.filter((u) => u.searchParams.get("start") === WINDOW.startISO);
    assert.ok(current.length >= 2, "the reported window is used by more than one call");
    for (const u of current) assert.equal(u.searchParams.get("end"), WINDOW.endISO);
  })();
});

test("an incomplete badge set is disclosed rather than left silent", async () => {
  // A full page of genuinely-new issues means some NEW marks are missing, and
  // an absent badge is indistinguishable from a problem that is not new.
  // Disclosed rather than thrown: reaching 100 new issues in one window means a
  // catastrophic release, which is exactly when the ranked list is most worth
  // reading.
  const newIssues = Array.from({ length: 100 }, (_, i) => ({
    shortId: `EW-${i}`, firstSeen: "2026-08-05T12:00:00Z",
  }));
  const { lines } = await render({ problems: [problemRow("EW-1", "paste_failed", 1, 1)], newIssues });
  assert.match(lines.join("\n"), /the NEW marks below are not complete/);
});

test("a normal badge set says nothing about completeness", async () => {
  // Two-way control: the disclosure must appear ONLY when the page was full.
  const { lines } = await render({
    problems: [problemRow("EW-1", "paste_failed", 1, 1)],
    newIssues: [{ shortId: "EW-1", firstSeen: "2026-08-05T12:00:00Z" }],
  });
  assert.doesNotMatch(lines.join("\n"), /not complete/);
});

test("a generated ordinal never collides with a label that already exists", () => {
  // The exact shape review proved: counting duplicates first and numbering them
  // produces `same (1)` twice when a row is ALREADY called `same (1)`.
  const row = (shortId, label) =>
    ({ shortId, people: 1, events: 1, group: LOST, label, deliveryProven: true, isNew: false });
  // TWO shapes, because they defeat different wrong implementations and the
  // first alone left a mutation alive:
  //   a) three identical labels - a single bump produces `same (1)` twice,
  //      since it cannot advance past an ordinal it has already used;
  //   b) a duplicate plus a row already NAMED `same (1)` - a count-then-number
  //      pass collides with the pre-existing label.
  for (const labels of [
    ["same", "same", "same"],
    ["same", "same", "same (1)"],
    ["same", "same", "same", "same (1)", "same (2)"],
  ]) {
    const data = {
      empty: false, floor: "2.4.0", tailPeople: 0,
      people: labels.length, priorPeople: labels.length, events: labels.length, truncated: false,
      rows: labels.map((label) => row(null, label)),
    };
    const rendered = formatSentrySection(data, { title: "Sentry" }).filter((l) => l.startsWith("  1 person"));
    assert.equal(rendered.length, labels.length, `all rows render for ${JSON.stringify(labels)}`);
    assert.equal(new Set(rendered).size, labels.length,
      `rows must render distinctly for ${JSON.stringify(labels)}, got ${JSON.stringify(rendered)}`);
  }
});

test("even the fixed empty-section copy is checked against the budget", () => {
  // The two empty paths return short fixed text, which is exactly why it was
  // tempting to let them skip the final check. A guard with exceptions is not a
  // guard, and a budget small enough proves the check is actually applied.
  for (const data of [{ empty: true, reason: "no-errors" }, { empty: true, reason: "no-release-line" }]) {
    assert.throws(() => formatSentrySection(data, { title: "Sentry", budget: 10 }), RangeError,
      `${data.reason} must be budget-checked too`);
    // Two-way: it renders normally at a sane budget.
    assert.ok(formatSentrySection(data, { title: "Sentry" }).length === 2);
  }
});

test("a people total too large to be exact is refused, never published", () => {
  // Each addend is a validated safe integer; their SUM need not be. An earlier
  // version returned a fabricated ZERO here, which reads as "nobody is on an
  // old build" - the one answer this line must never give.
  const huge = Number.MAX_SAFE_INTEGER;
  assert.throws(() => resolveReleaseLine([
    // All three tie on people, so the NEWEST wins and the floor is 2.4.0.
    { release: "com.enviouswispr.app@2.4.3", "count_unique(user)": huge },
    { release: "com.enviouswispr.app@2.3.1", "count_unique(user)": huge },
    { release: "com.enviouswispr.app@2.2.0", "count_unique(user)": huge },
  ]), TypeError);
});

test("an event total too large to be exact is refused, never published", async () => {
  const huge = Number.MAX_SAFE_INTEGER;
  const { fetchFn } = digestFetch({
    problems: [problemRow("EW-1", "asr_failed", 1, huge), problemRow("EW-2", "paste_failed", 1, huge)],
  });
  await assert.rejects(() => fetchSentrySection(ENV, WINDOW, { ...OPTS, fetchFn }), TypeError);
});
