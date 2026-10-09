// Observability Contract: the founder must not receive false counts, cohorts or
// novelty. Harness Contract: real shared readers exercise wire shapes/retries.
import { test } from "node:test";
import assert from "node:assert/strict";
import { fetchSentryWriteup, formatSentryWriteup } from "../../reporting/sentry-writeup.js";
import { discoverAggregate, issueList } from "../../shared/sentry.js";

import { ENV, WINDOW, problem, head, detail, rig } from "../fixtures/sentry-writeup-fixture.js";

const read = (r) => fetchSentryWriteup(ENV, WINDOW, r.opts);
const render = (data) => formatSentryWriteup(data, { platform: "mac", date: "2026-10-07" });
const next = (url) => { const u = new URL(url); u.searchParams.set("cursor", "100:1:0"); return "<" + u + ">; rel=\"next\"; results=\"true\"; cursor=\"100:1:0\""; };

test("write-up uses six real-reader queries with no production/release floor and exact occurrence trend", async () => {
  const r = rig(); const data = await read(r); const payload = render(data);
  assert.equal(r.requests.length, 6);
  assert.ok(r.peak() <= 2 && r.peak() > 0);
  const events = r.requests.filter((u) => u.pathname.endsWith("/events/"));
  assert.equal(events.length, 5);
  for (const u of events) {
    const fields = u.searchParams.getAll("field");
    const expected = fields.includes("release")
      ? ["issue", "environment", "app.build_type", "release", "error.category", "level", "count()"]
      : fields.includes("issue")
        ? ["issue", "environment", "app.build_type", "count()", "count_unique(user)"]
        : ["environment", "app.build_type", "count()", "count_unique(user)"];
    assert.deepEqual([...fields].sort(), expected.sort());
    assert.equal(u.searchParams.get("query"), "(event.type:error OR event.type:default) level:[error,fatal]");
    assert.equal(u.searchParams.has("environment"), false);
    assert.equal(u.searchParams.getAll("field").includes("app.build_type"), true);
    assert.equal(u.searchParams.has("statsPeriod"), false);
  }
  assert.equal(data.sections[0].problems[0].isNew, false);
  assert.match(payload.embeds[0].description, /5 events \(\+3 vs prior day\); 2 reported users \(\+1 vs prior day\)/);
  assert.match(payload.embeds[0].description, /ENVIOUSWISPR-1.*5 events.*\+3 events vs prior.*2\.5\.3/);
});

test("only complete empty metadata-backed queries produce a zero report", async () => {
  const r = rig({ current: [], prior: [], matrix: [], currentHead: [], priorHead: [] });
  const data = await read(r); const text = render(data).embeds[0].description;
  assert.equal(data.sections.every((s) => s.current.events === 0 && s.current.usersExact), true);
  assert.match(text, /No crash\/error events received/);
  assert.doesNotMatch(text, /crash.free|healthy|no bugs/i);
});

test("debug overrides production and missing environment; missing release evidence remains unknown", async () => {
  const current = [problem(1, 2, 1, "production", "debug"), problem(2, 3, 1, null, "debug"), problem(3, 4, 2, "production", null)];
  const r = rig({ current, prior: [], matrix: [detail(1, 2, "production", "debug"), detail(2, 3, null, "debug"), detail(3, 4, "production", null)],
    currentHead: [head(2, 1, "production", "debug"), head(3, 1, null, "debug"), head(4, 2, "production", null)], priorHead: [] });
  const data = await read(r);
  assert.equal(data.sections[0].current.events, 0);
  assert.deepEqual(data.sections[1].current, { events: 5, users: 1, eventsExact: true, usersExact: false });
  assert.equal(data.sections[2].current.events, 4);
  assert.match(render(data).embeds[0].description, /at least 1 reported user \(user change unavailable\)/);
});

test("identities never sum across conflicting metadata rows or issue rows", async () => {
  const r = rig({ current: [problem(1, 3, 2, "development", "debug"), problem(1, 4, 3, "production", "debug"), problem(2, 1, 1, "development", "debug")],
    currentHead: [head(4, 2, "development", "debug"), head(4, 3, "production", "debug")], prior: [], priorHead: [],
    matrix: [detail(1, 3, "development", "debug"), detail(1, 4, "production", "debug"), detail(2, 1, "development", "debug")] });
  const data = await read(r); const s = data.sections[1];
  assert.equal(s.current.events, 8); assert.equal(s.current.users, 3); assert.equal(s.current.usersExact, false);
  assert.equal(s.problems[0].events, 7); assert.equal(s.problems[0].users, 3); assert.equal(s.problems[0].usersExact, false);
});

test("firstSeen is absolute, and a genuinely new issue is distinct from a repeat in this window", async () => {
  const r = rig({ firstSeen: [{ shortId: "ENVIOUSWISPR-1", firstSeen: "2026-10-07T04:01:00Z" }] });
  const data = await read(r); assert.equal(data.sections[0].problems[0].isNew, true);
  const url = r.requests.find((u) => u.pathname.includes("/projects/"));
  assert.equal(url.searchParams.get("query"), "issue.category:error firstSeen:>=2026-10-07T04:00:00 firstSeen:<2026-10-08T04:00:00");
  assert.match(render(data).embeds[0].description, /new; 5 events/);
});

test("short first-seen pages follow validated cursors regardless of Link attribute order", async () => {
  const reorderedNext = (url) => next(url).replace('rel="next"; results="true"', 'results="true"; rel="next"');
  const r = rig({
    firstSeen: [{ shortId: "ENVIOUSWISPR-2", firstSeen: "2026-10-07T04:01:00Z" }],
    firstSeenLink: reorderedNext,
    firstSeenPage2: [{ shortId: "ENVIOUSWISPR-1", firstSeen: "2026-10-07T04:02:00Z" }],
  });
  const data = await read(r);
  assert.equal(r.requests.filter((u) => u.pathname.includes("/projects/")).length, 2);
  assert.equal(data.newnessComplete, true);
  assert.equal(data.sections[0].problems[0].isNew, true);
  assert.match(render(data).embeds[0].description, /ENVIOUSWISPR-1.*new; 5 events/);
});

test("older version activity and missing version detail remain in the counts", async () => {
  const r = rig({ matrix: [detail(1, 2, "production", "release", "com.enviouswispr.app@2.1.2"), detail(1, 3, "production", "release", null)] });
  const data = await read(r);
  assert.equal(data.sections[0].current.events, 5);
  assert.match(render(data).embeds[0].description, /2\.1\.2, unknown version/);
});

test("Android numeric build metadata renders the app version while malformed suffixes stay unknown", async () => {
  // TelemetryConfig.release emits package@versionName+appBuild. When this
  // fails, the morning report hides the affected Android app version.
  const r = rig({ matrix: [
    detail(1, 2, "production", "release", "com.envi.wispr@0.1.0+256"),
    detail(1, 3, "production", "release", "com.envi.wispr@0.1.0+bad"),
  ] });
  const data = await read(r);
  assert.deepEqual(data.sections[0].problems[0].versions, ["0.1.0", "unknown version"]);
  const payload = formatSentryWriteup(data, { platform: "android", date: "2026-10-07" });
  assert.match(payload.embeds[0].description, /0\.1\.0, unknown version/);
  assert.equal(data.sections[0].current.events, 5);
});

test("invalid numeric responses never turn into zero or plausible rounded values", async () => {
  for (const value of [null, "5", false, [], 1.5, -1, Number.MAX_SAFE_INTEGER + 1]) {
    const r = rig({ current: [{ ...problem(1, 5, 2), "count()": value }] });
    await assert.rejects(read(r), /invalid count/);
  }
  await assert.rejects(read(rig({ currentHead: [head(1, 2)] })), /users exceed events/);
});

test("complete problem/header disagreement refuses a misleading snapshot", async () => {
  await assert.rejects(read(rig({ currentHead: [head(6, 2)] })), /issue\/headline totals disagree/);
});

test("missing response metadata fails even when rows are empty", async () => {
  await assert.rejects(read(rig({ currentHead: [], currentHeadMeta: {} })), /meta.fields is missing/);
});

test("bounded pagination keeps the same query and follows only cursor metadata", async () => {
  const first = Array.from({ length: 100 }, (_, i) => problem(i + 1, 1, 1));
  const all = [...first, problem(101, 1, 1)];
  const r = rig({ current: first, currentLink: next, currentPage2: [problem(101, 1, 1)], currentHead: [head(101, 1)],
    prior: [], priorHead: [], matrix: first.map((x) => detail(x["issue.id"], 1)), matrixLink: next,
    matrixPage2: [detail(101, 1)] });
  const data = await read(r);
  assert.equal(data.issuesComplete, true);
  assert.equal(data.sections[0].problems.length, 101);
  const second = r.requests.find((u) => u.searchParams.has("cursor") && !u.searchParams.getAll("field").includes("release"));
  assert.equal(second.searchParams.get("project"), ENV.SENTRY_PROJECT_ID);
  assert.equal(second.searchParams.get("query"), "(event.type:error OR event.type:default) level:[error,fatal]");
  assert.equal(second.searchParams.get("cursor"), "100:1:0");
});

test("explicit terminal full pages keep exact counts and newness at both page boundaries", async () => {
  const terminal = (url) => next(url).replace('results="true"', 'results="false"');
  for (const total of [100, 200]) {
    const rows = Array.from({ length: total }, (_, i) => problem(i + 1, 1, 1));
    const matrix = rows.map((row) => detail(row["issue.id"], 1));
    const fresh = rows.map((row) => ({ shortId: row.issue, firstSeen: "2026-10-07T04:01:00Z" }));
    const r = rig({
      current: rows.slice(0, 100), currentLink: total === 100 ? terminal : next,
      currentPage2: rows.slice(100), currentPage2Link: terminal,
      matrix: matrix.slice(0, 100), matrixLink: total === 100 ? terminal : next,
      matrixPage2: matrix.slice(100), matrixPage2Link: terminal,
      firstSeen: fresh.slice(0, 100), firstSeenLink: total === 100 ? terminal : next,
      firstSeenPage2: fresh.slice(100), firstSeenPage2Link: terminal,
      currentHead: [head(total, 1)], prior: [], priorHead: [],
    });
    const data = await read(r);
    assert.equal(data.issuesComplete, true, `${total}: issue completeness`);
    assert.equal(data.buildsComplete, true, `${total}: build completeness`);
    assert.equal(data.newnessComplete, true, `${total}: newness completeness`);
    assert.equal(data.sections[0].problems.length, total);
    assert.equal(data.sections[0].current.events, total);
    assert.equal(data.sections[0].problems.every((p) => p.isNew && p.eventsExact), true);
    assert.equal(r.requests.length, total === 100 ? 6 : 9);
  }
});

test("a capped issue with one visible row stays bounded; hidden prior rows are not zero", async () => {
  const current = Array.from({ length: 100 }, (_, i) => problem(i + 1, 1, 1, "development", "debug"));
  const prior = Array.from({ length: 100 }, (_, i) => problem(i + 201, 1, 1, "development", "debug"));
  const r = rig({ current, prior, matrix: current.map((x) => detail(x["issue.id"], 1, "development", "debug")),
    currentHead: [head(150, 2, "development", "debug")], priorHead: [head(130, 2, "development", "debug")] });
  const data = await read(r); const p = data.sections[1].problems[0];
  assert.equal(data.issuesComplete, false); assert.equal(data.priorComplete, false);
  assert.equal(p.eventsExact, false); assert.equal(p.usersExact, false); assert.equal(p.previous.eventsExact, false);
  const text = render(data).embeds[0].description;
  assert.match(text, /at least 1 event; at least 1 reported user; event change unavailable/);
  assert.match(text, /150 events \(\+20 vs prior day\)/);
  assert.match(text, /Problem lists are incomplete/);
});

test("budget omissions are explicit and leave a visible developer problem", async () => {
  const rows = Array.from({ length: 40 }, (_, i) => problem(i + 1, 1, 1));
  const r = rig({ current: [...rows, problem(99, 3, 1, "development", "debug")], prior: [], priorHead: [],
    currentHead: [head(40, 1), head(3, 1, "development", "debug")],
    matrix: [...rows.map((x) => ({ ...detail(x["issue.id"], 1), title: "do_not_publish_this_private_text" })), detail(99, 3, "development", "debug")] });
  const text = render(await read(r)).embeds[0].description;
  assert.ok(text.length <= 3800); assert.match(text, /Showing \d+ of 40 returned problems/);
  assert.match(text, /ENVIOUSWISPR-99/); assert.doesNotMatch(text, /do_not_publish_this_private_text|contact_email/);
  for (const u of r.requests) assert.equal(u.searchParams.getAll("field").some((f) => ["title", "exception.value", "user.id", "user.email"].includes(f)), false);
});

test("cursor protocol is opt-in, preserving old response shape", async () => {
  const r = rig();
  const base = { queryName: "compat", fields: ["count()"], start: WINDOW.startISO, end: WINDOW.endISO };
  const data = await discoverAggregate(ENV, base, r.opts);
  assert.deepEqual(Object.keys(data).sort(), ["fields", "rows", "truncated"]);
  const list = await issueList(ENV, { queryName: "compat", limit: 100, start: WINDOW.startISO, end: WINDOW.endISO }, r.opts);
  assert.deepEqual(Object.keys(list).sort(), ["issues", "truncated"]);
});

test("both real readers distinguish explicit terminal pages from absent or previous-only metadata", async () => {
  const terminal = (url) => next(url).replace('results="true"', 'results="false"');
  const previous = (url) => terminal(url).replace('rel="next"', 'rel="previous"');
  for (const link of [terminal, previous, undefined]) {
    const r = rig({ current: Array.from({ length: 100 }, (_, i) => problem(i + 1, 1, 1)), currentLink: link,
      firstSeen: Array.from({ length: 100 }, (_, i) => ({ shortId: "ENVIOUSWISPR-" + (i + 1), firstSeen: "2026-10-07T04:01:00Z" })), firstSeenLink: link });
    const params = { queryName: "terminal_contract", fields: ["issue", "count()"], requiredFields: ["issue.id", "count()"],
      start: WINDOW.startISO, end: WINDOW.endISO, perPage: 100 };
    const listParams = { queryName: "terminal_contract", limit: 100, start: WINDOW.startISO, end: WINDOW.endISO };
    for (const data of [await discoverAggregate(ENV, { ...params, includeCursor: true }, r.opts),
      await issueList(ENV, { ...listParams, includeCursor: true }, r.opts)]) {
      assert.equal(data.terminalPage, link === terminal);
      assert.equal(data.nextCursor, null);
      assert.equal(data.truncated, true); // Legacy weekly hint is unchanged.
    }
    for (const data of [await discoverAggregate(ENV, params, r.opts), await issueList(ENV, listParams, r.opts)]) {
      assert.equal(Object.hasOwn(data, "terminalPage"), false);
      assert.equal(Object.hasOwn(data, "nextCursor"), false);
      assert.equal(data.truncated, true);
    }
  }
});

test("foreign or ambiguous cursor metadata is refused before a second request", async () => {
  for (const link of ["garbage", "<https://evil.invalid/events/?cursor=x>; rel=\"next\"; results=\"true\"", "<https://us.sentry.io/wrong/?cursor=x>; rel=\"next\"; results=\"true\"",
    "<https://us.sentry.io/api/0/organizations/envious-labs-llc/events/>; rel=\"next\"",
    "<https://us.sentry.io/api/0/organizations/envious-labs-llc/events/>; rel=\"next\"; results=\"false\", <https://us.sentry.io/api/0/organizations/envious-labs-llc/events/>; rel=\"next\"; results=\"false\"",
    "<https://us.sentry.io/api/0/organizations/envious-labs-llc/events/?cursor=x&cursor=y>; rel=\"next\"; results=\"true\"",
    "<https://us.sentry.io/api/0/organizations/envious-labs-llc/events/?cursor=x>; rel=\"next\"; results=\"false\", <https://us.sentry.io/api/0/organizations/envious-labs-llc/events/?cursor=y>; rel=\"next\"; results=\"true\""] ) {
    const r = rig({ currentLink: link });
    await assert.rejects(read(r), /pagination|next[- ]page/);
    assert.equal(r.requests.some((u) => u.searchParams.has("cursor")), false);
  }
});

test("invalid issue identity and duplicate grouping rows are loud", async () => {
  await assert.rejects(read(rig({ current: [{ ...problem(1, 5, 2), "issue.id": "1" }] })), /invalid issue identity/);
  await assert.rejects(read(rig({ current: [problem(1, 2, 1), problem(1, 3, 1)] })), /duplicate grouping row/);
});
